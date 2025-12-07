# Construire des images de VM Azure avec Packer (HCL2) et pipelines Azure DevOps (YAML)

_Auteur: Julien SANDULACHE_
_Date: décembre 2025_

## 1. Introduction

Imaginez ne plus devoir attendre 20 minutes que votre VM termine ses mises à jour avant de pouvoir lancer votre application. C'est ce que promettent les golden images: on build tout une fois, on déploie partout. Dans ce guide nous allons:

- Assembler un projet Packer modulaire ciblant Windows Server 2022.
- Exécuter la construction depuis Azure DevOps avec des pipelines YAML.
- Publier l'image finalisée dans une Azure Compute Gallery (ACG) pour que n'importe quelle VM, VM Scale Set (VMSS) ou Azure Virtual Desktop (AVD) puisse la consommer.

Je ferai référence à des fichiers du dossier `base-w2022-datacenter` dans ce dépôt et à deux schémas pour visualiser le flux:

- [Image factory diagram](./media/image-factory.drawio.svg)
- [Azure Pipelines conceptual diagram](./media/azure-devops-ci-cd-architecture.svg)

## 2. Pourquoi les images personnalisées comptent toujours

Avant d'écrire la moindre ligne, clarifions le pourquoi. Les images custom aident lorsque:

- **Vous êtes confronté à des temps de démarrage longs.** Installer .NET, IIS, des correctifs ou des language packs pendant le déploiement ralentit l'autoscaling ou les bascules blue/green.
- **Vous recherchez la cohérence.** Distribuer le même OS pré durci partout réduit la dérive et les moments « ça marchait en staging ».
- **Vos auditeurs veulent des preuves.** Si les contrôles CIS (Center for Internet Security Benchmarks) ou STIG (Security Technical Implementation Guides) sont intégrés dans une image, il suffit d'auditer ce pipeline plutôt que chaque VM après coup.
- **Les coûts augmentent.** Des déploiements plus rapides signifient moins de temps agent et moins d'échecs.

Si vous voulez une expérience managée, Azure Image Builder est parfait. Mais si vous préférez le contrôle total, la parité multi-cloud et la possibilité d'exécuter Packer en local pour expérimenter, rester sur des fichiers Packer natifs reste la solution la plus flexible.

## 3. Outils nécessaires (et versions testées)

| Composant | Version / Notes | Nécessaire / Facultatif / Souhaitable  |
| --------- | --------------- | ------ |
| Packer CLI | 1.14.x (syntaxe HCL2 avec `packer { required_plugins { ... } }`) | Nécessaire |
| Azure Packer plugin | `github.com/hashicorp/azure` >= 2.0.0 | Nécessaire |
| Azure CLI | 2.63+ pour les smoke tests, vérifications de galerie et nettoyage | Facultatif |
| Azure DevOps Agent | Cet article se base sur `ubuntu-latest` | Nécessaire |
| PowerShell dans la VM | Windows PowerShell 5.1 (par défaut sur Windows Server 2022) | Nécessaire |
| Linters utiles | `packer fmt`, `pwsh` Script Analyzer, `shellcheck` | Souhaitable |

N'hésitez pas à utiliser des versions plus récentes, mais figez-les dans les variables de votre pipeline pour obtenir un comportement identique à chaque run. Quand vous mettez à jour, faites-le intentionnellement.

## 4. Architecture en un coup d'œil

À un niveau macro, le flux ressemble à ceci (issu du schéma Microsoft, simplifié ci-dessous):

```text
Git Repo (Packer + scripts) --> Azure DevOps Pipeline --> Ephemeral Build Resource Group
                                              |--> Azure Compute Gallery (Image Definition + Versions)
                                                                     |--> VM / VMSS / AVD
```

- Le dépôt Git stocke les templates Packer, scripts PowerShell et YAML de pipeline.
- Azure DevOps récupère le dépôt, exécute la validation, construit l'image et publie journaux et métadonnées.
- Packer crée une VM temporaire, la configure, capture une image et (optionnellement) la pousse vers une Azure Compute Gallery.
- Les services référencent l'image de galerie en précisant la version ou via `latest` selon votre politique de diffusion.

## 5. Étape 1 - Explorer la structure du dépôt

Dans le dossier `base-w2022-datacenter` vous trouverez cette arborescence:

```shell
base-w2022-datacenter/
  build.pkr.hcl                         # PowerShell provisioners et logique Sysprep
  custom_vars.auto.pkrvars.hcl          # Remplacements des variables locaux pour tester rapidement
  locals.pkr.hcl                        # Définition de la variable local.computed_tags
  plugins.pkr.hcl                       # Bloc `required_plugins` (HashiCorp Azure plugin)
  source.pkr.hcl                        # azure-arm builder (credentials, VM size, gallery toggle)
  variables.pkr.hcl                     # Variables et leurs valeurs par défaut mappées aux variables d'environnement / inputs pipeline
  scripts/
    Cleanup.ps1                         # Nettoyage final avant Sysprep
    Configure-Windows-Firewall.ps1      # Verrouille les ports WinRM/RDP
    Install-FR-Language.ps1             # Installe le language pack français
    Install-Windows-Defender.ps1        # Installe et configure Windows Defender
```

Pourquoi séparer les fichiers ?

- Vous pouvez changer l'image source ou la taille de VM sans toucher aux provisioners.
- Les équipes se répartissent les responsabilités: les ingénieurs plateforme ajustent `source.pkr.hcl`, les équipes applicatives modifient les scripts.
- Les diffs Git restent lisibles, ce qui simplifie les revues de code.

## 6. Étape 2 - Comprendre le fichier de variables

`variables.pkr.hcl` définit « ce qui peut changer selon l'environnement ». Voici un extrait représentatif:

```hcl
variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
  default     = "${env("ARM_TENANT_ID")}"
}

.....

variable "managed_image_name" {
  type        = string
  description = "The managed image name"
  default     = "${env("PKR_VAR_IMAGE_NAME")}"
}

..... 

variable "common_tags" {
  type = map(string)
  default = {
    Environment = "Staging"
    CreatedBy   = "Packer"
    Purpose     = "base-Image"
    OS          = "Windows"
  }
}
```

À retenir:

- Lisez les credentials Azure depuis les variables d'environnement `ARM_*` pour n'avoir aucun secret en dur.
- Fournissez des valeurs par défaut (`France Central`, `Standard_D4s_v5`, etc.) mais attendez-vous à ce que le pipeline les override via `PKR_VAR_*`.
- Laissez vides les variables liées à la galerie tant que vous n'avez pas une galerie déployée - ainsi les tests créent seulement une managed image.

## 7. Étape 3 - Configurer le bloc builder

`source.pkr.hcl` décrit comment Packer communique avec la machine virtuelle Azure:

```hcl
source "azure-arm" "image" {
  subscription_id                   = var.subscription_id
  temp_resource_group_name          = var.build_resource_group_name
  communicator                      = "winrm"
  winrm_use_ssl                     = true
  winrm_insecure                    = true
  winrm_timeout                     = var.winrm_timeout
  managed_image_name                = var.managed_image_name
  managed_image_resource_group_name = var.managed_image_resource_group_name
  # shared_image_gallery_destination { ... } # enable later
  azure_tags                        = local.computed_tags
}
```

- WinRM est sécurisé avec SSL par défaut `winrm_insecure = true`, et `winrm_insecure = true` reste activé uniquement pour le bootstrap afin d'autoriser les premières connexions. Votre script de configuration du firewall verrouille ensuite.
- Les entrées optionnelles pour définir un VNet sont commentées. Décommentez-les si votre organisation impose que les builds aient lieu dans un sous-réseau privé.
- `local.computed_tags` fusionne `var.common_tags` avec des tags calculés contenant des valeurs du pipeline (commit git ou version d'image) afin que chaque artefact embarque les informations de traçabilité.

## 8. Étape 4 - Chaîner les provisioners

`build.pkr.hcl` décrit « ce qui se passe dans la VM ». Les provisioners s'exécutent dans l'ordre, chacun avec une responsabilité claire:

| Étape | Fichier ou bloc inline | Raison |
| ---- | ----------------------- | ------ |
| 1 | Inline readiness check | Attendre que WinRM soit stable avant de toucher à l'OS. |
| 2 | Inline IIS install | Installer le rôle Web-Server et démarrer `W3SVC` automatiquement. |
| 3 | `scripts/Install-FR-Language.ps1` | Ajouter le language pack FR pour coller aux besoins du workload. |
| 4 | `scripts/Install-Windows-Defender.ps1` | S'assurer que Defender et ses signatures existent même sans egress Internet. |
| 5 | `scripts/Configure-Windows-Firewall.ps1` | Restreindre WinRM/RDP selon votre politique. |
| 6 | `scripts/Cleanup.ps1` | Purger les dossiers temporaires pour réduire l'image. |
| 7 | Boucle Sysprep (inline) | Lancer Sysprep et sonder le registre jusqu'au statut `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`. |

Tous les scripts s'exécutent avec le compte `SYSTEM`, ce qui leur permet de modifier services et rôles sans credentials supplémentaires. Gardez-les idempotents - chaque script vérifie si le changement est déjà appliqué avant d'agir.

## 9. Étape 5 - Taguer et versionner

La traçabilité vous fait gagner des heures quand il faut retrouver qui a créé une certaine image. Un pattern simple consiste à:

- Utiliser `local.computed_tags` dans `source.pkr.hcl` pour la traçabilité.

```shell
locals {
  computed_tags = merge(var.common_tags, {
    gitRef          = var.run_id != "" ? var.run_id : "manual"
    imageVersion    = var.gallery_image_version
    imageName       = var.gallery_image_name != "" ? var.gallery_image_name : "${var.managed_image_name}-img"
    buildDate       = formatdate("YYYY-MM-DD", timestamp())
    baselineVersion = var.baseline_version

  })
}
```

- Depuis le pipeline, passer `-var "run_id=$(Build.SourceVersion)"` et `-var "image_version=${IMAGE_VERSION}"` pour garder des tags exacts.
- Publier un fichier `metadata/image-version.json` (voir Étape 7) contenant version, ID de galerie, commit git et run du pipeline.

Ainsi quiconque consulte l'image dans Azure Portal visualise son origine.

## 10. Étape 6 - Brancher le pipeline Azure DevOps

Nous pouvons utiliser un pipeline à cinq étapes: **Validate → Build → Test → Approve → Release**.

1. **Validate** - Les linters et contrôles de sécurité tournent vite pour échouer en moins d'une minute si la syntaxe est cassée.
2. **Build** - Seule étape autorisée à créer des versions de galerie. Elle tourne sur la branche `main` (ajustez les filtres).
3. **Test** - Déploie une VM temporaire depuis l'image créée, lance un smoke test (IIS ici) puis supprime le resource group.
4. **Approve** - Porte d'entrée manuelle vers la promotion production.
5. **Release** - Ajoute des tags git, met à jour la doc ou déclenche des déploiements aval.

Pour simplifier, nous exécutons ici une version réduite avec uniquement Validate et Build. Le YAML complet se trouve dans le dépôt sous `.pipelines/packer.yml`.

### 10.1 Inquiétudes et mitigations

| Inquiétude | Mitigation |
| ---------- | ---------- |
| Secrets divulgués dans les logs | Utiliser OIDC + variable groups Key Vault pour que rien ne soit stocké en clair dans le YAML. |
| Version différente à chaque exécution | Calculer `IMAGE_VERSION`, la stocker via `##vso[task.setvariable]` et la réutiliser à chaque étape. |
| Boucles de feedback lentes | Lancer `packer fmt`, `packer init` et `packer validate -syntax-only` dans Validate avant la construction de l'image. |
| Difficulté à reproduire un échec | Publier `build.log`, le résumé du pipeline et le JSON de métadonnées en artefacts. |
| « Ça a marché mais personne ne l'a testé » | Toujours déployer la VM de smoke test et lancer le curl check avant les approvals. |

### 10.2 Extrait YAML (raccourci pour que soit lisible)

```yaml
parameters:
  - name: versionStrategy
    type: string
    default: date
    values: [ date, semver ]

stages:
  - stage: Validate
    jobs:
      - job: lint
        steps:
          - task: Bash@3
            name: calcVersion
            script: |
              if [ '${{ parameters.versionStrategy }}' = 'date' ]; then
                VERSION=$(date +%Y.%m.%d).$((RANDOM % 90 + 10))
              else
                VERSION="1.0.$(date +%H%M)"
              fi
              echo "##vso[task.setvariable variable=IMAGE_VERSION;isOutput=true]$VERSION"
          - script: |
              cd base-w2022-datacenter
              packer init .
              packer fmt -check .
              packer validate -syntax-only build.pkr.hcl
            displayName: Quick template checks

  - stage: Build
    dependsOn: Validate
    variables:
      IMAGE_VERSION: $[ stageDependencies.Validate.lint.outputs['calcVersion.IMAGE_VERSION'] ]
    jobs:
      - job: packer_build
        steps:
          - task: AzureCLI@2
            displayName: Login with OIDC
            inputs:
              azureSubscription: svc-conn-oidc-image-build
          - task: Bash@3
            env:
              ARM_CLIENT_ID: $(ARM_CLIENT_ID)
              ARM_TENANT_ID: $(ARM_TENANT_ID)
              ARM_SUBSCRIPTION_ID: $(ARM_SUBSCRIPTION_ID)
              PKR_VAR_IMAGE_NAME: $(paramPackerImageName)-${{ parameters.environment }}
            script: |
              cd base-w2022-datacenter
              packer build -color=false \
                -var "gallery_image_version=${IMAGE_VERSION}" \
                -var "run_id=$(Build.SourceVersion)" \
                build.pkr.hcl | tee build.log
          - publish: base-w2022-datacenter/build.log
            artifact: packer-log
```

Vous pouvez ajouter d'autres étapes, mais cet extrait montre l'essentiel: calculer la version une fois, la réutiliser partout et toujours publier les logs.

### 10.3 Sauvegarder les métadonnées

Juste après un build réussi, capturez les informations de galerie. Cela simplifie les rollbacks et audits:

```bash
SIG_VERSION_ID=$(az sig image-version show --gallery-name acg-shared \
  --gallery-image-definition windows-web-base \
  --gallery-image-version ${IMAGE_VERSION} \
  -g rg-img-gallery --query id -o tsv)

cat <<EOF > metadata/image-version.json
{
  "imageVersion": "${IMAGE_VERSION}",
  "sigVersionId": "${SIG_VERSION_ID}",
  "gitCommit": "$(Build.SourceVersion)",
  "buildId": "$(Build.BuildId)"
}
EOF
```

Publiez ce fichier en artefact aux côtés de `build.log`.

## 11. Étape 7 - Gérer secrets et accès

- **Identité:**
  - Utilisez l'identité de workload Azure DevOps (OIDC) tant que possible. Cela supprime les secrets longue durée.
  - OIDC fonctionne très bien avec le builder Azure ARM de Packer pour les pipelines courts car il délivre des tokens éphémères. En cas de blocage, basculez vers un service principal dont le secret est stocké dans Key Vault.
- **Moindre privilège:**
  - Créez un rôle RBAC custom scope sur le resource group temporaire et la galerie. Inutile d'accorder Contributor au niveau subscription.
- **Key Vault:**
  - Les groups de variables reliés à Key Vault facilitent la rotation des secrets sans toucher au YAML. Attribuez uniquement `get` et `list` pour les Key Vaults en Access Policies et le rôle `Azure Key Vault Secrets User` pour ceux gérés en RBAC.
- **Logging:**
  - Considérez les logs de build comme sensibles. Même avec OIDC, évitez de lister des credentials ou réponses de tokens.

## 12. Étape 8 - Tester, dépanner et itérer

Voici les problèmes les plus courants et comment réagir:

| Symptôme | Cause probable | Correctif rapide |
|---------|----------------|------------------|
| WinRM ne se connecte jamais | Port 5986 bloqué ou certificat self-signed non approuvé | Vérifier que `winrm_insecure = true`. |
| Language pack échoue | Windows Update désactivé ou package absent | Héberger les CAB dans un blob storage et adapter `Install-FR-Language.ps1`. |
| Mise à jour Defender bloque | Pas d'egress Internet | Utiliser `Update-MpSignature -DefinitionUpdateFile` pointant vers un partage interne. |
| Sysprep s'arrête instantanément | Updates en attente ou services actifs | Inspecter `C:\Windows\System32\Sysprep\Panther\setuperr.log` et relancer après nettoyage. |
| Version de galerie bloquée en « Creating » | Quota de la région ou mauvaise liste de réplication | Exécuter `az sig image-version show` pour lire `provisioningState` et ajuster les régions. |
| Authentification WinRM échoue | Mot de passe ou CredSSP incorrect | Vérifier les credentials, activer CredSSP, aligner les paramètres `winrm`. |
| SSH time out | Port 22 bloqué ou cloud-init incomplet | Vérifier les NSG, s'assurer que la VM est provisionnée avant la connexion Packer. |
| Échec provisioning Azure image build | Identité managée incorrecte ou droits insuffisants | Assigner les rôles RBAC appropriés (Contributor) à l'identité utilisée. |
| Packer ne trouve pas le resource group | Nom ou région incorrecte | Vérifier `resource_group_name` et `location` dans le template. |
| Script custom échoue sans message | Chemin faux ou permissions manquantes | Utiliser des chemins absolus, vérifier les droits et activer les logs verbeux. |
| Capture d'image échoue | VM non généralisée (Sysprep non lancé) | S'assurer que Sysprep termine avant la capture. |
| Build bloque sur l'étape Azure ARM | Latence réseau ou plugin `azure-arm` manquant | Mettre Packer à jour et vérifier l'installation du plugin. |
| Erreur « Authentication failed » | Credentials du service principal expirés ou mauvais tenant | Renouveler les credentials et vérifier `tenant_id`, `client_id`, `client_secret`. |
| Erreur « Resource quota exceeded » | Quotas subscription atteints | Contrôler les quotas Azure et demander une extension si besoin. |

Si rien ne fonctionne, activez les logs verbeux Packer avec `PACKER_LOG=1` et `PACKER_LOG_PATH=packer-debug.log`. Désactivez-les une fois le souci réglé.

## 13. Étape 9 - Surveiller les coûts

- Utilisez la plus petite taille de VM capable de terminer vos scripts (`Standard_D4s_v5` suffit ici).
- Limitez la réplication de galerie aux régions réellement consommatrices. La réplication représente souvent le coût caché principal.
- Purgez les anciennes versions (gardez les N dernières ou celles de moins de X jours) pour garder la galerie propre. Automatisez avec Azure CLI dans le pipeline.
- Synchronisez les builds planifiés avec les mises à jour "Patch Tuesday" et les correctifs urgents au lieu de reconstruire tous les jours inutilement.

## 14. Checklist finale et prochaines étapes

1. Clonez le dépôt et lancez `packer init` puis `packer validate` en local pour prendre la main.
2. Personnalisez `variables.pkr.hcl` et les scripts PowerShell pour refléter les exigences de votre projet.
3. Créez le pipeline Azure DevOps, connectez-le au dépôt et testez d'abord l'étape Validate.
4. Une fois le pipeline opérationnel, activez le bloc galerie, publiez les métadonnées et partagez la version avec vos équipes VM/VMSS/AVD.
5. Ajoutez les deux schémas évoqués au début à vos favoris - ils sont parfaits pour expliquer ce flux à vos collègues ou reviewers.

Voilà. Vous disposez maintenant d'une démarche reproductible pour produire des "golden images" avec Packer et Azure DevOps. Commencez simple, célébrez la première version publiée dans la galerie puis ajoutez progressivement plus d'automatisation (réplication multi-région, contrôles de policy, smoke tests automatisés) à mesure que la confiance augmente.

Sources et pour aller plus loin:

- [Packer Commands Official Documentation](https://developer.hashicorp.com/packer/docs/commands)
- [Packer Azure ARM Builder Documentation](https://www.packer.io/plugins/builders/azure/arm)
- [Azure Compute Gallery Documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/azure-compute-gallery)
- [Azure DevOps YAML Pipelines Documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/yaml-schema)
- [Windows Sysprep Documentation](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/sysprep--system-preparation--overview)

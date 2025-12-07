# Building Azure VM Images with Packer (HCL2) and Azure DevOps YAML Pipelines

_Author: Julien SANDULACHE_
_Date: December 2025_

## 1. Introduction

Imagine never having to wait 20 minutes for a VM to finish installing updates before your app can boot. That is the promise of golden images: create everything once, deploy anywhere. In this guide we will:

- Assemble a modular Packer project that targets Windows Server 2022.
- Run the build from Azure DevOps using YAML pipelines.
- Publish the finished image into an Azure Compute Gallery (ACG) so any VM, VM Scale Set (VMSS), or Azure Virtual Desktop (AVD) host can consume it.

I will reference files from the `base-w2022-datacenter` folder in this repo and point to two official diagrams so you can visualize the flow:

- [Image factory diagram](./media/image-factory.drawio.svg)
- [Azure Pipelines conceptual diagram](./media/azure-devops-ci-cd-architecture.svg)

## 2. Why Custom Images Still Matter

Before diving into code, let’s be clear about the "why." Custom images help when:

- **You are fighting long boot times.** Installing .NET, IIS, patches, or language packs during deployment slows down autoscaling or blue/green rollouts.
- **You need consistency.** Shipping the same pre-hardened OS everywhere reduces drift and "it worked on staging" moments.
- **Your auditors want proof.** If CIS (Center for Internet Security Benchmarks) or STIG (Security Technical Implementation Guides) controls are built into an image, you only need to review that pipeline rather than every VM after the fact.
- **Costs are creeping up.** Faster deployments mean less agent time and fewer failed releases.

If you want a managed experience, Azure Image Builder is great. However, if you prefer maximum control, multi-cloud parity, and the ability to run Packer locally for experiments, sticking with native Packer files is the most flexible option.

## 3. Tools You Need (and Tested Versions)

| Component | Version / Notes | Required / Optional / Nice to have |
| --------- | --------------- | --------------------------------- |
| Packer CLI | 1.14.x (HCL2 syntax with `packer { required_plugins { ... } }`) | Required |
| Azure Packer plugin | `github.com/hashicorp/azure` >= 2.0.0 | Required |
| Azure CLI | 2.63+ for smoke tests, gallery checks, and clean-up | Optional |
| Azure DevOps Agent | This article is based on `ubuntu-latest` | Required |
| PowerShell inside VM | Windows PowerShell 5.1 (default on Windows Server 2022) | Required |
| Helpful linters | `packer fmt`, `pwsh` Script Analyzer, `shellcheck` | Nice to have |

Feel free to use newer versions, but pin them in your pipeline variables so every run behaves the same. When you upgrade, do it intentionally.

## 4. Architecture at a Glance

At a high level the flow looks like this (pulled straight from the Microsoft diagram, simplified below):

```text
Git Repo (Packer + scripts) --> Azure DevOps Pipeline --> Ephemeral Build Resource Group
                                              |--> Azure Compute Gallery (Image Definition + Versions)
                                                                     |--> VM / VMSS / AVD
```

- The Git repo stores the Packer templates, PowerShell scripts, and pipeline YAML.
- Azure DevOps pulls the repo, runs validation, builds the image, and publishes logs and metadata.
- Packer spins up a temporary VM, configures it, captures an image, and (optionally) publishes it to an Azure Compute Gallery.
- Downstream services reference the gallery image by version or "latest," depending on your rollout policy.

## 5. Step 1 - Explore the Repo Structure

In the `base-w2022-datacenter` folder you will find this layout:

```shell
base-w2022-datacenter/
  build.pkr.hcl                         # PowerShell provisioners and Sysprep logic
  custom_vars.auto.pkrvars.hcl          # Local overrides for quick testing
  locals.pkr.hcl                        # local.computed_tags definition
  plugins.pkr.hcl                       # required_plugins block (HashiCorp Azure plugin)
  source.pkr.hcl                        # azure-arm builder (credentials, VM size, gallery toggle)
  variables.pkr.hcl                     # Defaults that map to env vars / pipeline inputs
  scripts/
    Cleanup.ps1                         # Final cleanup before Sysprep
    Configure-Windows-Firewall.ps1      # Lock down WinRM/RDP ports
    Install-FR-Language.ps1             # Add French language pack
    Install-Windows-Defender.ps1        # Install and configure Windows Defender
```

Why separate files?

- You can change the source image or the VM size without touching the provisioner logic.
- Teams can own different parts: platform engineers tweak `source.pkr.hcl`, app teams adjust scripts.
- Git diffs stay clean, making code reviews easier.

## 6. Step 2 - Understand the Variables File

`variables.pkr.hcl` is where we define "things you might change per environment." Here is a trimmed excerpt:

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

What to remember:

- Read Azure credentials from `ARM_*` environment variables so you never hardcode secrets.
- Provide defaults (`France Central`, `Standard_D4s_v5`, etc.) but expect the pipeline to override them with `PKR_VAR_*` values.
- Leave gallery-related variables empty until you have an actual gallery in place - this way the executions create only a managed image.

## 7. Step 3 - Configure the Builder Block

`source.pkr.hcl` is where we tell Packer how to talk to the Azure VM:

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

- WinRM is secured with SSL by default `winrm_insecure = true`, and we keep `winrm_insecure = true` just for the bootstrap stage so that initial connections can succeed. Your firewall script will lock it down later.
- Optional VNet inputs are commented out. Uncomment them if your organization requires builds to happen inside a private subnet.
- `local.computed_tags` merges `var.common_tags` with computed tags with pipeline-provided values (like git commit or image version) so every artifact carries traceability information.

## 8. Step 4 - Chain the Provisioners

`build.pkr.hcl` is the "what happens inside the VM" file. Provisioners run in order and each one has a clear responsibility:

| Step | File or Inline Block | Why we do it |
| ---- | -------------------- | ------------ |
| 1 | Inline readiness check | Wait for WinRM to become stable before touching the OS. |
| 2 | Inline IIS install | Install the Web-Server role and start `W3SVC` automatically. |
| 3 | `scripts/Install-FR-Language.ps1` | Add the French language pack to match the workload requirements. |
| 4 | `scripts/Install-Windows-Defender.ps1` | Make sure Defender and its signatures exist even in offline networks. |
| 5 | `scripts/Configure-Windows-Firewall.ps1` | Restrict WinRM/RDP to only what your policy allows. |
| 6 | `scripts/Cleanup.ps1` | Clear temp folders and Windows Update leftovers to shrink the image. |
| 7 | Sysprep loop (inline) | Run Sysprep once and poll the registry until the VM reaches `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`. |

All scripts run with the `SYSTEM` account so they can modify services and install roles without additional credentials. Keep them idempotent - each script should check if the change was already applied before doing anything.

## 9. Step 5 - Tag and Version Everything

Traceability saves hours when you debug who created which image. A simple pattern is:

- Use `local.computed_tags` inside `source.pkr.hcl` for traceability.

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

- From the pipeline, pass `-var "run_id=$(Build.SourceVersion)"` and `-var "image_version=${IMAGE_VERSION}"` so those tags stay accurate.
- Publish a `metadata/image-version.json` file (see Step 7) with the version, gallery ID, git commit, and pipeline run.

Now anyone browsing the image in Azure Portal can see its lineage.

## 10. Step 6 - Wire Up the Azure DevOps Pipeline

We can use a five-stage pipeline: **Validate → Build → Test → Approve → Release** :

1. **Validate stage** - Linters and safety checks run fast so you fail in under a minute if syntax is broken.
2. **Build stage** - The only stage allowed to create gallery versions. It runs on the `main` branch (adjust filters as needed).
3. **Test stage** - Deploys a temporary VM from the newly created image, hits a smoke-test endpoint (IIS in this example), and deletes the resource group afterward.
4. **Approve stage** - Manual gate for production promotion.
5. **Release stage** - Applies git tags, updates documentation, or triggers downstream deployments.

Note: For simplicity, we run a trimmed version here with just Validate and Build stages. The full YAML example is found in the repo as `.pipelines/packer.yml`.

### 10.1 Concerns and Mitigations

| Concern | Mitigation |
| ------- | ---------- |
| Secrets leaked in logs | Use Azure DevOps OIDC connections plus Key Vault-backed variable groups so nothing is stored in plain YAML. |
| Different version each run | Have a job calculate `IMAGE_VERSION`, store it via `##vso[task.setvariable]`, and reuse it in every stage. |
| Slow feedback loops | Run `packer fmt`, `packer init`, and `packer validate -syntax-only` in the Validate stage before doing the heavy build. |
| Hard to reproduce failures | Publish `build.log`, pipeline summary, and the metadata JSON to artifacts. |
| "It worked but no one tested it" | Always run the smoke-test VM deployment and curl check before approvals. |

### 10.2 YAML Excerpt (Trimmed for Clarity)

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

You can keep stacking stages, but this snippet shows the core ideas: compute the version once, reuse it everywhere, and always publish logs.

### 10.3 Save the Metadata

Right after the build succeeds, capture the gallery information. This makes rollbacks and audits painless:

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

Publish that file as an artifact together with `build.log`.

## 11. Step 7 - Keep Secrets and Access Simple

- **Identity:**
  - Use Azure DevOps workload identity federation wherever possible. It removes the need for long-lived client secrets.
  - In my experience, OIDC works flawlessly with Packer’s Azure ARM builder for short-lived pipelines because it issues short-lived tokens automatically. If you hit issues, fallback to a service principal with a secret stored in Key Vault.
- **Least privilege:**
  - Create a custom RBAC role scoped to the temporary build resource group plus the gallery resource group. No need for subscription-wide Contributor.
- **Key Vault:**
  - Variable groups linked to Key Vault make it easy to rotate secrets without touching YAML. Grant only `get` and `list` permissions for Key Vaults with Access Policies and `Azure Key Vault Secrets User` role assignments for Key Vaults using RBAC.
- **Logging:**
  - Treat build logs as sensitive. Even when using OIDC, avoid printing credentials or raw token responses.

## 12. Step 8 - Test, Troubleshoot, and Iterate

Here are the most common issues beginners hit and how to recover:

| Symptom                                | Likely Cause                                                                 | Quick Fix                                                                                           |
|----------------------------------------|------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| WinRM never connects                   | Port 5986 blocked or self-signed cert not trusted                           | Ensure `winrm_insecure = true` .            |
| Language pack fails                    | Windows Update disabled or package missing                                  | Host CAB files in blob storage and update `Install-FR-Language.ps1` to fetch from there. |
| Defender update hangs                  | No internet egress                                                          | Use `Update-MpSignature -DefinitionUpdateFile` pointing to an internal share. |
| Sysprep quits instantly                | Pending updates or services still running                                   | Inspect `C:\Windows\System32\Sysprep\Panther\setuperr.log` and rerun after clearing pending tasks. |
| Gallery version stuck "Creating"       | Region quota or wrong replication list                                      | Run `az sig image-version show` to inspect `provisioningState` and adjust the replication regions. |
| WinRM authentication fails             | Wrong username/password or CredSSP not enabled                              | Verify credentials, enable CredSSP, and ensure `winrm` settings match Packer template.            |
| SSH connection times out               | Port 22 blocked or cloud-init not finished                                  | Check NSG rules, ensure VM is fully provisioned before Packer tries to connect.                   |
| Azure image build fails at provisioning| Incorrect managed identity or insufficient permissions                       | Assign correct RBAC roles (e.g., Contributor) to the identity used by Packer.                     |
| Packer cannot find resource group      | Wrong resource group name or region mismatch                                | Double-check `resource_group_name` and `location` in your Packer template.                        |
| Custom script fails silently           | Script path incorrect or missing execution permissions                       | Use absolute paths, verify permissions, and enable verbose logging in Packer template.            |
| Image capture fails                    | VM not generalized (Sysprep not run)                                        | Ensure Sysprep completes successfully before Packer captures the image.                           |
| Build hangs on Azure ARM step          | Network latency or missing `azure-arm` plugin                               | Update Packer to latest version and verify plugin installation.                                    |
| Error: "Authentication failed"         | Service principal credentials expired or wrong environment                   | Refresh SP credentials, verify `tenant_id`, `client_id`, and `client_secret`.                     |
| Error: "Resource quota exceeded"       | Subscription quota limits reached                                            | Check Azure subscription quotas and request increases if needed.                                   |

If all else fails, enable verbose Packer logging using `PACKER_LOG=1` and `PACKER_LOG_PATH=packer-debug.log`. Just remember to disable it once the issue is resolved.

## 13. Step 9 - Mind the Costs

- Use the smallest VM size that comfortably completes your provisioning scripts (`Standard_D4s_v5` works well here).
- Limit gallery replication to regions that actually consume the image. Replication is the biggest hidden cost.
- Prune old image versions (keep the last N or versions younger than X days) so your gallery stays tidy. Can be automated with Azure CLI in the pipeline.
- Align scheduled builds with "Patch Tuesday" plus ad-hoc security releases instead of rebuilding daily for no reason.

## 14. Final Checklist and Next Steps

1. Clone the repo and run `packer init` + `packer validate` locally to get comfortable.
2. Customize `variables.pkr.hcl` and the PowerShell scripts so they match your organization’s project requirements.
3. Create the Azure DevOps pipeline, connect it to the repo, and test the Validate stage first.
4. Once the pipeline builds successfully, enable the gallery block, publish metadata, and share the version with your VM/VMSS/AVD teams.
5. Bookmark the two diagrams linked at the top - they are great references when explaining this flow to teammates or reviewers.

That’s it! You now have a repeatable roadmap for producing golden images with Packer and Azure DevOps. Start simple, celebrate the first successful gallery version, and layer on more automation (multi-region replication, policy checks, automated smoke tests) as confidence grows.

Sources and Further Reading:

- [Packer Commands Official Documentation](https://developer.hashicorp.com/packer/docs/commands)
- [Packer Azure ARM Builder Documentation](https://www.packer.io/plugins/builders/azure/arm)
- [Azure Compute Gallery Documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/azure-compute-gallery)
- [Azure DevOps YAML Pipelines Documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/yaml-schema)
- [Windows Sysprep Documentation](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/sysprep--system-preparation--overview)

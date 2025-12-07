build {
  name = var.build_name

  sources = [
    "source.azure-arm.image"
  ]

  provisioner "powershell" {
    inline = [
      "Write-Host 'Starting configuration...'",
      "Write-Host 'WinRM is ready!'",
      "Get-Date"
    ]
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Patching & Enabling IIS'",
      "Install-WindowsFeature -Name Web-Server",
      "Set-Service W3SVC -StartupType Automatic",
      "Write-Host 'Applying baseline hardening placeholder'"
    ]
  }

  provisioner "powershell" {
    elevated_user     = "SYSTEM"
    elevated_password = ""
    script            = "scripts/Install-FR-Language.ps1"
    execution_policy  = var.execution_policy
  }

  provisioner "powershell" {
    elevated_user     = "SYSTEM"
    elevated_password = ""
    script            = "scripts/Install-Windows-Defender.ps1"
    execution_policy  = var.execution_policy
  }

  provisioner "powershell" {
    elevated_user     = "SYSTEM"
    elevated_password = ""
    script            = "scripts/Configure-Windows-Firewall.ps1"
    execution_policy  = var.execution_policy
  }

  provisioner "powershell" {
    elevated_user     = "SYSTEM"
    elevated_password = ""
    script            = "scripts/Cleanup.ps1"
    execution_policy  = var.execution_policy
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Preparing Sysprep...'",
      "if (Test-Path 'C:/Windows/system32/sysprep/unattend.xml') { Remove-Item 'C:/Windows/system32/sysprep/unattend.xml' -Force }",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit",
      "while($true) {",
      "  $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State | Select ImageState",
      "  if($imageState.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $imageState.ImageState; Start-Sleep -s 10 } else { break }",
      "}"
    ]
  }
}
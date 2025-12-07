Add-WindowsCapability -Online -Name "Language.Basic~~~fr-FR~0.0.1.0"

Set-WinSystemLocale -SystemLocale fr-FR
Set-WinDefaultInputMethodOverride -InputTip "040c:0000040c"
Set-WinHomeLocation -GeoId 84
Set-Culture -CultureInfo fr-FR
Set-WinUILanguageOverride -Language fr-FR

New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue

$DefaultUserPath = "HKU:\.DEFAULT\Control Panel\International"
$DefaultUserParent = "HKU:\.DEFAULT\Control Panel"

if (!(Test-Path $DefaultUserParent)) {
    New-Item -Path $DefaultUserParent -Force
}
if (!(Test-Path $DefaultUserPath)) {
    New-Item -Path $DefaultUserPath -Force
}

Set-ItemProperty -Path $DefaultUserPath -Name "LocaleName" -Value "fr-FR"
Set-ItemProperty -Path $DefaultUserPath -Name "sCountry" -Value "France"
Set-ItemProperty -Path $DefaultUserPath -Name "sLanguage" -Value "FRA"
Set-ItemProperty -Path $DefaultUserPath -Name "Locale" -Value "0000040c"

Write-Host "Configuration completed."
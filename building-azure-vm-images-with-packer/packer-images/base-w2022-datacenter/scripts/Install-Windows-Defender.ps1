Install-WindowsFeature -Name "Windows-Defender" -IncludeAllSubFeature -IncludeManagementTools -Restart:$false

$Services = @("WinDefend", "WdNisSvc", "Sense", "SecurityHealthService")
foreach ($ServiceName in $Services) {
    try {
        $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($Service) {
            Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction SilentlyContinue
            Write-Host "Service $ServiceName configured for automatic startup"
        } else {
            Write-Host "Service $ServiceName not found"
        }
    } catch {
       Write-Host "Error configuring service ${ServiceName}: $($_.Exception.Message)"
    }
}

Start-Sleep -Seconds 10

try {
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
    Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue
    Set-MpPreference -SubmitSamplesConsent SendAllSamples -ErrorAction SilentlyContinue
    Set-MpPreference -ScanAvgCPULoadFactor 25 -ErrorAction SilentlyContinue
    Set-MpPreference -ScanOnlyIfIdleEnabled $true -ErrorAction SilentlyContinue
    Set-MpPreference -EnableNetworkProtection Enabled -ErrorAction SilentlyContinue
    
    Write-Host "Basic preferences configured"
    
    Set-MpPreference -ScanScheduleDay Sunday -ErrorAction SilentlyContinue
    Set-MpPreference -ScanScheduleTime 02:00:00 -ErrorAction SilentlyContinue
    Set-MpPreference -ScanParameters FullScan -ErrorAction SilentlyContinue
    
    Write-Host "Scheduled scan configured (Sunday 2:00 AM)"
    
} catch {
    Write-Host "Error configuring preferences: $($_.Exception.Message)"
}

Write-Host "Configuring server exclusions..."
try {
    $ServerExclusions = @(
        "C:\Windows\System32\LogFiles\",
        "C:\Windows\System32\config\",
        "C:\Windows\Logs\",
        "C:\Windows\SoftwareDistribution\",
        "C:\Windows\Temp\",
        "C:\ProgramData\Microsoft\Windows Defender\"
    )
    
    foreach ($Exclusion in $ServerExclusions) {
        try {
            Add-MpPreference -ExclusionPath $Exclusion -ErrorAction SilentlyContinue
            Write-Host "Exclusion added: $Exclusion"
        } catch {
            Write-Host "Cannot add exclusion $Exclusion"
        }
    }
} catch {
    Write-Host "Error adding exclusions: $($_.Exception.Message)"
}
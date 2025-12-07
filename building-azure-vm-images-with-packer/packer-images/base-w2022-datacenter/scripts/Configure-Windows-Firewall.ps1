Write-Host "Configuring Windows Firewall..."
try {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -ErrorAction SilentlyContinue
    Write-Host "Windows Firewall configured"
} catch {
    Write-Host "Error configuring firewall: $($_.Exception.Message)"
}
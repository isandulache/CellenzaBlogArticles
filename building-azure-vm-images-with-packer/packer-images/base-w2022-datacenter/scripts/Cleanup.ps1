Write-Host "Starting temporary files cleanup..."
Write-Host "Cleaning Windows temporary folders..."
$tempPaths = @(
    "$env:SystemRoot\Temp\*",
    "$env:SystemRoot\SoftwareDistribution\Download\*",
    "$env:SystemRoot\Logs\CBS\*",
    "$env:SystemRoot\Logs\DISM\*",
    "$env:SystemRoot\Logs\NetSetup\*",
    "$env:SystemRoot\Panther\*",
    "$env:SystemRoot\WinSxS\ManifestCache\*",
    "$env:SystemRoot\WinSxS\Temp\*"
)

foreach ($path in $tempPaths) {
    try {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleaned: $path"
        }
    }
    catch {
        Write-Host "Unable to clean: $path"
    }
}

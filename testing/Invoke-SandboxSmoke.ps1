<#
.SYNOPSIS
    One-shot smoke test for Windows Sandbox: audit -> apply -> audit.
    Validates the full launcher/manifest/payload chain on a disposable
    machine. NOT a substitute for a clean-VM test (Sandbox has no Store
    appx, no OneDrive, no Entra profile, and cannot reboot).
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$raw = 'https://raw.githubusercontent.com/Cylon-Consulting/endpoint-baseline/main'

Write-Host "=== Sandbox smoke test ===" -ForegroundColor Cyan
Invoke-RestMethod "$raw/Get-BaselineState.ps1"      -OutFile C:\audit.ps1
Invoke-RestMethod "$raw/Invoke-EndpointBaseline.ps1" -OutFile C:\launcher.ps1

Write-Host "`n--- BEFORE ---" -ForegroundColor Yellow
powershell -ExecutionPolicy Bypass -File C:\audit.ps1 -OutFile C:\before.json

Write-Host "`n--- APPLY ---" -ForegroundColor Yellow
powershell -ExecutionPolicy Bypass -File C:\launcher.ps1 -ManifestUrl "$raw/manifest.json"
$applyExit = $LASTEXITCODE
Write-Host "Launcher exit code: $applyExit"

Write-Host "`n--- AFTER ---" -ForegroundColor Yellow
powershell -ExecutionPolicy Bypass -File C:\audit.ps1 -OutFile C:\after.json

if ($applyExit -eq 0) { Write-Host "`nSMOKE TEST PASSED (review DIFF counts above)" -ForegroundColor Green }
else { Write-Host "`nSMOKE TEST FAILED - launcher exit $applyExit" -ForegroundColor Red }
Write-Host "Sandbox is disposable - close the window to discard everything."

<#
.SYNOPSIS
    Local test of UNPUSHED payload changes on a real workstation:
    audit -> apply -> audit, straight from this working copy. No manifest,
    no launcher, nothing fetched from GitHub. Complements
    Invoke-SandboxSmoke.ps1, which tests what is already on main.

.DESCRIPTION
    Copy the whole repo folder to the test machine and run this elevated.

    Default config is testing\local-delta-config.json: only the toggles
    changed in the 2026-11-24 upstream review (activityHistory,
    preventDeviceCompanionApps, edgePromotionsOff,
    startMenuRecommendationsOff) plus the restore point. Everything else in
    the baseline is switched off, so nothing is uninstalled and no services
    or tasks are touched.

    -AuditOnly  Read-only: run the audit and stop. Changes nothing.
    -Full       Apply payload\efficiency-config.json instead - the complete
                baseline, including appx removal. Same as a fleet run.

    Exit codes: 0 = payload succeeded and every targeted setting matches,
    3 = payload failed or a targeted setting does not match, 2 = could not
    start.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\testing\Invoke-LocalTest.ps1 -AuditOnly
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\testing\Invoke-LocalTest.ps1
#>
[CmdletBinding()]
param(
    [switch]$AuditOnly,
    [switch]$Full
)

$ErrorActionPreference = 'Stop'

$root    = Split-Path $PSScriptRoot -Parent
$audit   = Join-Path $root 'Get-BaselineState.ps1'
$payload = Join-Path $root 'payload\Invoke-EfficiencyBaseline.ps1'
$config  = if ($Full) { Join-Path $root 'payload\efficiency-config.json' }
           else       { Join-Path $PSScriptRoot 'local-delta-config.json' }

foreach ($f in $audit, $payload, $config) {
    if (-not (Test-Path $f)) {
        Write-Host "Missing $f - copy the whole repo folder, not just testing\." -ForegroundColor Red
        exit 2
    }
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Must run elevated (the audit and payload both read every user hive).' -ForegroundColor Red
    exit 2
}

$outDir = Join-Path $env:TEMP 'eb-localtest'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$before = Join-Path $outDir 'before.json'
$after  = Join-Path $outDir 'after.json'

# Audit rows this change set is expected to move. Labels must match
# Get-BaselineState.ps1.
$targets = @(
    'Activity feed (1 keeps Win+V)'
    'Upload user activities'
    'Device companion apps'
    'Edge recommendations'
    'Edge shopping assistant'
    'Edge Rewards'
    'Edge default-browser campaigns'
    'Edge Spotlight recommendations'
    'Edge feedback prompts'
    'Edge wallet donation'
    'Edge Acrobat button'
    'Start suggested websites'
    'Start menu recommendations'
)

if ($AuditOnly) {
    Write-Host '=== Audit only - nothing will be changed ===' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $audit -OutFile $before
    Write-Host "`nRows targeted by the pending change set:" -ForegroundColor Yellow
    (Get-Content $before -Raw | ConvertFrom-Json).results |
        Where-Object { $targets -contains $_.Setting } |
        Format-Table Area, Setting, Current, Expected, Status -AutoSize
    exit 0
}

Write-Host '=== Local payload test ===' -ForegroundColor Cyan
Write-Host "Config: $config"
if ($Full) { Write-Host 'FULL baseline: includes appx removal, services and scheduled tasks.' -ForegroundColor Yellow }

Write-Host "`n--- BEFORE (audit, output saved to $before) ---" -ForegroundColor Yellow
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $audit -OutFile $before | Out-Null

Write-Host "`n--- APPLY ---" -ForegroundColor Yellow
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $payload -ConfigPath $config
$applyExit = $LASTEXITCODE
Write-Host "Payload exit code: $applyExit"

Write-Host "`n--- AFTER (audit, output saved to $after) ---" -ForegroundColor Yellow
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $audit -OutFile $after | Out-Null

$b = (Get-Content $before -Raw | ConvertFrom-Json).results
$a = (Get-Content $after  -Raw | ConvertFrom-Json).results
$bIdx = @{}
foreach ($r in $b) { $bIdx["$($r.Area)|$($r.Setting)"] = $r }

$changed = @(foreach ($r in $a) {
    $o = $bIdx["$($r.Area)|$($r.Setting)"]
    if ($o -and "$($o.Current)" -ne "$($r.Current)") {
        [pscustomobject]@{ Area = $r.Area; Setting = $r.Setting; Before = $o.Current
                           After = $r.Current; Expected = $r.Expected; Status = $r.Status }
    }
})

Write-Host "`n--- CHANGED BY THIS RUN ($($changed.Count)) ---" -ForegroundColor Yellow
if ($changed.Count -gt 0) { $changed | Format-Table Area, Setting, Before, After, Expected, Status -AutoSize }
else { Write-Host 'Nothing changed - the machine already had these values.' }

$targetRows = @($a | Where-Object { $targets -contains $_.Setting })
$targetBad  = @($targetRows | Where-Object { $_.Status -ne 'MATCH' })
Write-Host "--- TARGETED SETTINGS ($($targetRows.Count - $targetBad.Count) of $($targetRows.Count) match) ---" -ForegroundColor Yellow
if ($targetBad.Count -gt 0) { $targetBad | Format-Table Area, Setting, Current, Expected, Status -AutoSize }

if ($applyExit -eq 0 -and $targetBad.Count -eq 0 -and $targetRows.Count -gt 0) {
    Write-Host "`nLOCAL TEST PASSED" -ForegroundColor Green
    Write-Host 'Now check by hand: Win+V opens clipboard history, and Settings > System > Clipboard'
    Write-Host 'is not marked as managed by your organisation. Sign out and back in first if it is.'
    exit 0
}
Write-Host "`nLOCAL TEST FAILED - payload exit $applyExit, $($targetBad.Count) targeted setting(s) not matching" -ForegroundColor Red
Write-Host "Payload transcript: $env:ProgramData\EfficiencyBaseline\logs"
exit 3

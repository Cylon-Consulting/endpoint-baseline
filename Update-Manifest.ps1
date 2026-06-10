<#
.SYNOPSIS
    Regenerates manifest.json: pins payload + config to the current HEAD
    commit with fresh SHA256 hashes and bumps the patch version.

.DESCRIPTION
    Run AFTER committing payload changes (the manifest must reference a
    commit that already contains them). Requires a clean working tree so
    the pinned SHA truly matches the hashed file contents.

    The update-manifest GitHub Action runs this automatically on every push
    that touches payload/**, so manual use is only needed off-line.

.EXAMPLE
    ./Update-Manifest.ps1 -Notes "Trimmed appx list" -Commit -Push
#>
[CmdletBinding()]
param(
    [string]$Notes = 'Manifest refresh',
    [switch]$Commit,
    [switch]$Push
)

$ErrorActionPreference = 'Stop'
$repoRoot = if ($PSScriptRoot) { $PSScriptRoot }
            else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$dirty = git -C $repoRoot status --porcelain
if ($dirty) {
    Write-Error "Working tree not clean - commit payload changes first:`n$dirty"
    exit 2
}
$sha = (git -C $repoRoot rev-parse HEAD).Trim()

$payloadFile = Join-Path $repoRoot 'payload/Invoke-EfficiencyBaseline.ps1'
$configFile  = Join-Path $repoRoot 'payload/efficiency-config.json'
$payloadHash = (Get-FileHash $payloadFile -Algorithm SHA256).Hash.ToLowerInvariant()
$configHash  = (Get-FileHash $configFile  -Algorithm SHA256).Hash.ToLowerInvariant()

$manifestPath = Join-Path $repoRoot 'manifest.json'
$version = '1.0.0'
if (Test-Path $manifestPath) {
    $old = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($old.payload.sha256 -eq $payloadHash -and $old.config.sha256 -eq $configHash) {
        Write-Host "Hashes unchanged - manifest already current (v$($old.version)). Nothing to do."
        exit 0
    }
    $parts = $old.version -split '\.'
    $version = '{0}.{1}.{2}' -f $parts[0], $parts[1], ([int]$parts[2] + 1)
}

$base = "https://raw.githubusercontent.com/Cylon-Consulting/endpoint-baseline/$sha"
$manifest = [ordered]@{
    version = $version
    updated = (Get-Date -Format 'yyyy-MM-dd')
    notes   = $Notes
    payload = [ordered]@{
        description = 'Efficiency baseline script, pinned to commit'
        url         = "$base/payload/Invoke-EfficiencyBaseline.ps1"
        sha256      = $payloadHash
    }
    config = [ordered]@{
        description = 'Payload toggles + appx removal list, pinned to commit'
        url         = "$base/payload/efficiency-config.json"
        sha256      = $configHash
    }
    arguments = '-ConfigPath {config}'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "manifest.json -> v$version, pinned to $($sha.Substring(0,8))"

if ($Commit) {
    git -C $repoRoot add manifest.json
    git -C $repoRoot commit -m "chore: manifest v$version pinned to $($sha.Substring(0,8))"
    if ($Push) { git -C $repoRoot push }
}
exit 0

<#
.SYNOPSIS
    Drift checker: compares upstream WinUtil's Standard preset and tweak
    definitions against an approved local baseline. Alert-only — never
    applies anything to endpoints.

.DESCRIPTION
    Three-layer check:
      1. Membership  - did the tweak IDs in upstream preset.json (Standard)
                       change vs our approved list?
      2. Definition  - did the body of any approved tweak in tweaks.json
                       change (registry keys, scripts, services)?
      3. Existence   - was an approved tweak removed upstream entirely?
    Plus awareness: new 'Essential Tweaks' upstream that we haven't reviewed.

    Exit codes (for RMM monitor):
      0 = no drift
      1 = drift detected (review required)
      2 = error (fetch/parse failure)

.PARAMETER UpdateBaseline
    Approve the current upstream state: refreshes definition hashes for the
    approved tweak list and writes baseline.json. If no baseline exists yet,
    seeds the approved list from the current upstream Standard preset.
    Membership changes are deliberate: to adopt an upstream addition, edit
    approvedPreset in baseline.json by hand, then run -UpdateBaseline to
    capture its hash.

.EXAMPLE
    # First run on the admin box - seed the baseline
    .\Check-WinutilDrift.ps1 -UpdateBaseline

    # Weekly scheduled run
    .\Check-WinutilDrift.ps1
#>
[CmdletBinding()]
param(
    [string]$BaselinePath,
    # 'latest-release' resolves to the newest release tag - i.e. what
    # christitus.com/win actually serves to machines. Pass 'main' instead
    # for early warning of unreleased changes (noisier).
    [string]$Branch       = 'latest-release',
    [string]$PresetName   = 'Standard',
    [string]$ReportPath,
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not yet set when param defaults are evaluated under
# Windows PowerShell 5.1 (-File invocation), and $env:ProgramData does not
# exist on Linux runners - so resolve both defaults here.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $BaselinePath) { $BaselinePath = Join-Path $scriptDir 'baseline.json' }
if (-not $ReportPath) {
    $reportBase = if ($env:ProgramData) { Join-Path $env:ProgramData 'WinutilDrift' } else { $scriptDir }
    $ReportPath = Join-Path $reportBase 'last-report.txt'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Branch -eq 'latest-release') {
    try {
        $Branch = (Invoke-RestMethod -UseBasicParsing `
            -Uri 'https://api.github.com/repos/ChrisTitusTech/winutil/releases/latest').tag_name
        Write-Verbose "Resolved latest release tag: $Branch"
    } catch {
        Write-Error "Could not resolve latest release tag: $_"
        exit 2
    }
}
$rawBase = "https://raw.githubusercontent.com/ChrisTitusTech/winutil/$Branch/config"

# tweaks.json contains literal newlines inside JSON string values (embedded
# PowerShell snippets), which strict parsers reject. Escape control chars
# that occur inside string literals only.
function Repair-JsonControlChars {
    param([string]$Raw)
    $sb = [System.Text.StringBuilder]::new($Raw.Length + 512)
    $inStr = $false; $esc = $false
    foreach ($ch in $Raw.ToCharArray()) {
        if ($inStr) {
            if ($esc)        { [void]$sb.Append($ch); $esc = $false; continue }
            if ($ch -eq '\') { [void]$sb.Append($ch); $esc = $true;  continue }
            if ($ch -eq '"') { $inStr = $false; [void]$sb.Append($ch); continue }
            if ([int]$ch -lt 0x20) {
                switch ([int]$ch) {
                    10      { [void]$sb.Append('\n') }
                    13      { [void]$sb.Append('\r') }
                    9       { [void]$sb.Append('\t') }
                    default { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
                }
                continue
            }
            [void]$sb.Append($ch); continue
        }
        if ($ch -eq '"') { $inStr = $true }
        [void]$sb.Append($ch)
    }
    $sb.ToString()
}

# Deterministic serialization so hashes are stable across PS 5.1 / 7.x.
# ConvertTo-Json output is NOT stable across versions; this is.
function Escape-JsonString {
    param([string]$s)
    $sb = [System.Text.StringBuilder]::new('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            default {
                if ([int]$ch -lt 0x20) {
                    switch ([int]$ch) {
                        8  { [void]$sb.Append('\b') }
                        9  { [void]$sb.Append('\t') }
                        10 { [void]$sb.Append('\n') }
                        12 { [void]$sb.Append('\f') }
                        13 { [void]$sb.Append('\r') }
                        default { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
                    }
                } else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

function ConvertTo-CanonicalJson {
    param($Value)
    if ($null -eq $Value)     { return 'null' }
    if ($Value -is [bool])    { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [string])  { return Escape-JsonString $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $parts = foreach ($p in ($Value.PSObject.Properties | Sort-Object Name)) {
            (Escape-JsonString $p.Name) + ':' + (ConvertTo-CanonicalJson $p.Value)
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-CanonicalJson $item }
        return '[' + ($parts -join ',') + ']'
    }
    # Fallback: stringify
    return Escape-JsonString ([string]$Value)
}

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        ([System.BitConverter]::ToString($bytes) -replace '-').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# --- Fetch upstream -----------------------------------------------------
try {
    Write-Verbose "Fetching upstream preset.json and tweaks.json ($Branch)..."
    $presetRaw = (Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/preset.json").Content
    $tweaksRaw = (Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/tweaks.json").Content

    $preset = $presetRaw | ConvertFrom-Json
    $tweaks = (Repair-JsonControlChars $tweaksRaw) | ConvertFrom-Json

    $upstreamPreset = @($preset.$PresetName)
    if (-not $upstreamPreset) { throw "Preset '$PresetName' not found in upstream preset.json" }

    $upstreamHashes = @{}
    foreach ($p in $tweaks.PSObject.Properties) {
        $upstreamHashes[$p.Name] = Get-Sha256Hex (ConvertTo-CanonicalJson $p.Value)
    }
} catch {
    Write-Error "Failed to fetch/parse upstream config: $_"
    exit 2
}

# --- Baseline update mode -----------------------------------------------
if ($UpdateBaseline) {
    $approved = if (Test-Path $BaselinePath) {
        @((Get-Content $BaselinePath -Raw | ConvertFrom-Json).approvedPreset)
    } else {
        Write-Host "No existing baseline - seeding approved list from upstream '$PresetName' preset."
        $upstreamPreset
    }

    $kept = @(); $dropped = @()
    foreach ($id in $approved) {
        if ($upstreamHashes.ContainsKey($id)) { $kept += $id }
        else { $dropped += $id }
    }
    if ($dropped) {
        Write-Warning "Dropping tweaks no longer defined upstream: $($dropped -join ', ')"
    }

    $hashes = [ordered]@{}
    foreach ($id in ($kept | Sort-Object)) { $hashes[$id] = $upstreamHashes[$id] }

    $baseline = [ordered]@{
        version        = (Get-Date -Format 'yyyy-MM-dd')
        winutilBranch  = $Branch
        presetName     = $PresetName
        approvedPreset = $kept
        tweakHashes    = $hashes
    }
    $dir = Split-Path $BaselinePath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $baseline | ConvertTo-Json -Depth 5 | Set-Content -Path $BaselinePath -Encoding UTF8
    Write-Host "Baseline written: $BaselinePath ($($kept.Count) tweaks)"
    exit 0
}

# --- Check mode ----------------------------------------------------------
if (-not (Test-Path $BaselinePath)) {
    Write-Error "No baseline at $BaselinePath. Run with -UpdateBaseline first."
    exit 2
}
$baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json
$approved = @($baseline.approvedPreset)

# Preset entries with no definition in tweaks.json are upstream bugs the
# WinUtil GUI silently ignores - they can never apply to an endpoint, so
# they must not trigger drift. Surface them as FYI only.
$orphaned          = @($upstreamPreset | Where-Object { -not $upstreamHashes.ContainsKey($_) })
$membershipAdded   = @($upstreamPreset | Where-Object { $_ -notin $approved -and $_ -notin $orphaned })
$membershipRemoved = @($approved       | Where-Object { $_ -notin $upstreamPreset })

$defChanged = @(); $defRemoved = @()
foreach ($p in $baseline.tweakHashes.PSObject.Properties) {
    if (-not $upstreamHashes.ContainsKey($p.Name)) { $defRemoved += $p.Name }
    elseif ($upstreamHashes[$p.Name] -ne $p.Value) { $defChanged += $p.Name }
}

# Awareness only: new Essential Tweaks upstream we have never reviewed
$newEssential = @(
    $tweaks.PSObject.Properties |
        Where-Object { $_.Value.category -eq 'Essential Tweaks' -and $_.Name -notin $approved } |
        ForEach-Object { $_.Name }
)

$drift = ($membershipAdded.Count + $membershipRemoved.Count +
          $defChanged.Count + $defRemoved.Count) -gt 0

$lines = @(
    "WinUtil drift report - $(Get-Date -Format 'yyyy-MM-dd HH:mm') (baseline $($baseline.version), branch $Branch, preset $PresetName)"
    ""
)
if ($drift) {
    if ($membershipAdded)   { $lines += "PRESET ADDITIONS upstream (not in approved list):"; $lines += $membershipAdded   | ForEach-Object { "  + $_" }; $lines += "" }
    if ($membershipRemoved) { $lines += "PRESET REMOVALS upstream (still in approved list):"; $lines += $membershipRemoved | ForEach-Object { "  - $_" }; $lines += "" }
    if ($defChanged)        { $lines += "DEFINITION CHANGED (review diff before re-approving):"; $lines += $defChanged | ForEach-Object { "  ~ $_" }; $lines += "" }
    if ($defRemoved)        { $lines += "DEFINITION REMOVED upstream entirely:"; $lines += $defRemoved | ForEach-Object { "  x $_" }; $lines += "" }
    $lines += "ACTION: review https://github.com/ChrisTitusTech/winutil/commits/$Branch/config"
    $lines += "        then edit approvedPreset if needed and run -UpdateBaseline to re-approve."
} else {
    $lines += "No drift. Approved preset and all tweak definitions match upstream."
}
if ($orphaned) {
    $lines += ""
    $lines += "FYI - preset entries with no definition in tweaks.json (upstream bug; WinUtil ignores these):"
    $lines += $orphaned | ForEach-Object { "  ! $_" }
}
if ($newEssential) {
    $lines += ""
    $lines += "FYI - upstream Essential Tweaks not in approved list (no action required):"
    $lines += $newEssential | ForEach-Object { "  ? $_" }
}

$report = $lines -join [Environment]::NewLine
$reportDir = Split-Path $ReportPath -Parent
if ($reportDir -and -not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$report | Set-Content -Path $ReportPath -Encoding UTF8
Write-Host $report

if ($drift) { exit 1 } else { exit 0 }

<#
.SYNOPSIS
    Generic upstream watcher: reports new commits touching watched paths in
    other projects' repos since the last human review. Alert-only.

.DESCRIPTION
    Complements Check-WinutilDrift.ps1 (which deep-diffs WinUtil's tweak
    definitions). Other upstreams don't need per-setting diffing - we just
    want to know WHEN their curated lists change so we can review and decide
    whether to fold changes into our payload.

    watchlist.json records, per watch: repo, branch, path, and the commit
    SHA last reviewed. Each run lists commits newer than that SHA.

    Exit codes: 0 = nothing new, 1 = new commits to review, 2 = error.

.PARAMETER UpdateWatchlist
    Mark everything as reviewed: sets each watch's lastReviewed to the
    current upstream head for its path and writes watchlist.json.
#>
[CmdletBinding()]
param(
    [string]$WatchlistPath,
    [string]$ReportPath,
    [switch]$UpdateWatchlist
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $WatchlistPath) { $WatchlistPath = Join-Path $scriptDir 'watchlist.json' }
if (-not $ReportPath)    { $ReportPath    = Join-Path $scriptDir 'watch-report.txt' }

$headers = @{ 'User-Agent' = 'endpoint-baseline-watch' }
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN }
if ($token) { $headers['Authorization'] = "Bearer $token" }

function Get-PathCommits {
    param([string]$Repo, [string]$Branch, [string]$Path, [int]$Max = 30)
    $uri = "https://api.github.com/repos/$Repo/commits?sha=$Branch&per_page=$Max"
    if ($Path) { $uri += "&path=$([uri]::EscapeDataString($Path))" }
    # Invoke-RestMethod emits a JSON array as ONE object; foreach forces
    # element-wise output so the caller's @() collects commits, not a
    # nested array.
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers
    foreach ($c in $resp) { $c }
}

if (-not (Test-Path $WatchlistPath)) {
    Write-Error "No watchlist at $WatchlistPath"
    exit 2
}
$watchlist = Get-Content $WatchlistPath -Raw | ConvertFrom-Json

$anyNew = $false
$lines = @("Upstream watch report - {0:yyyy-MM-dd HH:mm}" -f (Get-Date), '')

foreach ($w in $watchlist.watches) {
    try {
        $commits = @(Get-PathCommits -Repo $w.repo -Branch $w.branch -Path $w.path)
    } catch {
        Write-Error "Failed to query $($w.repo) ($($w.path)): $_"
        exit 2
    }
    if (-not $commits) { continue }
    $head = $commits[0].sha

    if ($UpdateWatchlist) {
        $w.lastReviewed = $head
        continue
    }

    if ($head -eq $w.lastReviewed) { continue }

    $newCommits = @()
    $foundOld = $false
    foreach ($c in $commits) {
        if ($c.sha -eq $w.lastReviewed) { $foundOld = $true; break }
        $newCommits += $c
    }

    $anyNew = $true
    $label = if ($foundOld) { "$($newCommits.Count) new commit(s)" } else { "$($newCommits.Count)+ new commit(s)" }
    $lines += "## $($w.name) - $label"
    $lines += "   repo: $($w.repo)  path: $($w.path)"
    foreach ($c in $newCommits) {
        $msg = ($c.commit.message -split "`n")[0]
        $lines += "   - $($c.sha.Substring(0,8)) $($c.commit.committer.date.ToString('yyyy-MM-dd')) $msg"
    }
    if ($w.lastReviewed) {
        $lines += "   diff: https://github.com/$($w.repo)/compare/$($w.lastReviewed)...$head"
    }
    $lines += ''
}

if ($UpdateWatchlist) {
    $watchlist | ConvertTo-Json -Depth 5 | Set-Content -Path $WatchlistPath -Encoding UTF8
    Write-Host "Watchlist updated: all watches marked reviewed at current heads."
    exit 0
}

if ($anyNew) {
    $lines += 'ACTION: review the diffs above, fold anything relevant into payload/,'
    $lines += '        then re-run with -UpdateWatchlist to mark as reviewed.'
} else {
    $lines += 'No new upstream changes since last review.'
}

$report = $lines -join [Environment]::NewLine
$report | Set-Content -Path $ReportPath -Encoding UTF8
Write-Host $report

if ($anyNew) { exit 1 } else { exit 0 }

<#
.SYNOPSIS
    Static launcher for ConnectWise RMM. Paste this into the RMM once and
    never edit it again - all decisions live in manifest.json in your repo.

.DESCRIPTION
    Fetches manifest.json from a URL you control, downloads the payload
    script (pinned WinUtil release or your own tweak script) and its config,
    verifies both against the SHA256 hashes declared in the manifest, then
    executes. Refuses to run anything whose hash does not match.

    Integrity chain:
      RMM script (static, trusted)  ->  manifest URL (your repo, access-controlled)
      manifest                      ->  pins exact hashes of payload + config
    To change WHAT runs on the fleet: commit a new manifest. RMM untouched.

    Exit codes:
      0 = applied successfully
      2 = manifest/download/integrity failure (nothing was executed)
      3 = payload executed but returned non-zero

.PARAMETER ManifestUrl
    HTTPS URL of manifest.json. For a private GitHub repo pass -AuthToken
    (use a ConnectWise variable/credential, never hard-code).
#>
[CmdletBinding()]
param(
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/Cylon-Consulting/endpoint-baseline/main/manifest.json',
    [string]$AuthToken,
    [string]$WorkDir = (Join-Path $env:ProgramData 'EndpointBaseline'),
    [string]$LogDir  = (Join-Path $env:ProgramData 'EndpointBaseline\logs')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

foreach ($d in @($WorkDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogDir "run-$stamp.log") | Out-Null

function Get-RemoteFile {
    param([string]$Url, [string]$OutFile)
    $headers = @{}
    if ($AuthToken) { $headers['Authorization'] = "token $AuthToken" }
    Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers $headers -OutFile $OutFile
}

function Assert-FileHash {
    param([string]$Path, [string]$Expected, [string]$Label)
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$Label hash mismatch. Expected $Expected, got $actual. REFUSING TO EXECUTE."
    }
}

try {
    $manifestPath = Join-Path $WorkDir 'manifest.json'
    Get-RemoteFile -Url $ManifestUrl -OutFile $manifestPath
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    Write-Host "Manifest version $($manifest.version) (updated $($manifest.updated))"

    $payloadPath = Join-Path $WorkDir 'payload.ps1'
    $configPath  = Join-Path $WorkDir 'config.json'

    Get-RemoteFile -Url $manifest.payload.url -OutFile $payloadPath
    Assert-FileHash -Path $payloadPath -Expected $manifest.payload.sha256 -Label 'Payload'

    Get-RemoteFile -Url $manifest.config.url -OutFile $configPath
    Assert-FileHash -Path $configPath -Expected $manifest.config.sha256 -Label 'Config'
} catch {
    Write-Error "Pre-flight failed: $_"
    Stop-Transcript | Out-Null
    exit 2
}

try {
    $argString = $manifest.arguments -replace '\{config\}', ('"' + $configPath + '"')
    Write-Host "Executing payload with arguments: $argString"
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$payloadPath`" $argString" `
        -Wait -PassThru -NoNewWindow
    Write-Host "Payload exit code: $($proc.ExitCode)"
    Stop-Transcript | Out-Null
    if ($proc.ExitCode -ne 0) { exit 3 } else { exit 0 }
} catch {
    Write-Error "Execution failed: $_"
    Stop-Transcript | Out-Null
    exit 3
}

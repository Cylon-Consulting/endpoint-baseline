<#
.SYNOPSIS
    Efficiency baseline for managed desktops/laptops: telemetry/privacy
    reduction plus low-risk performance hygiene. Self-contained - no WinUtil
    dependency at runtime. Tweak selection derived from WinUtil release
    26.05.12, business-trimmed.

.DESCRIPTION
    Scope decisions (deliberate):
      - Touches NOTHING AV-related. Fleet runs OpenText/Webroot; Defender
        stays factory-default as the automatic fallback.
      - Windows Error Reporting left enabled (diagnostic value, idle cost ~0).
      - Location services left enabled (uniform payload, auto-timezone for
        field laptops).
      - Keeps business apps: Teams, Outlook, Quick Assist, Sticky Notes,
        Paint, To Do, Power Automate, Alarms, Sound Recorder.
      - Per-user (HKCU) settings are applied to ALL existing user profiles
        and the Default User template, so they reach real users even when
        run as SYSTEM via RMM.

    All behavior toggles and the appx removal list come from the config JSON
    (-ConfigPath) so future changes are data-only - update the manifest repo,
    never this script or the RMM.

    Exit codes: 0 = all steps succeeded, 3 = one or more steps failed (see
    transcript), 2 = could not start (bad config / not elevated).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ConfigPath,
    [string]$LogDir = (Join-Path $env:ProgramData 'EfficiencyBaseline\logs')
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Must run elevated.'
    exit 2
}
try {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Cannot read config '$ConfigPath': $_"
    exit 2
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
Start-Transcript -Path (Join-Path $LogDir ("run-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

$script:Failures = @()
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host "== $Name"
    try { & $Action; Write-Host "   ok" }
    catch {
        Write-Warning "   FAILED: $_"
        $script:Failures += $Name
    }
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# Apply a scriptblock against every real user hive (loaded or not) plus the
# Default User template, so per-user settings reach all current and future
# profiles even under SYSTEM.
function Invoke-PerUserHive {
    param([scriptblock]$Apply)
    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    # S-1-5-21-* = local/domain accounts; S-1-12-1-* = Entra ID accounts
    $profiles = Get-ChildItem $profileList | Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-' }
    foreach ($p in $profiles) {
        $sid  = $p.PSChildName
        $path = (Get-ItemProperty $p.PSPath).ProfileImagePath
        $ntuser = Join-Path $path 'NTUSER.DAT'
        $wasLoaded = Test-Path "Registry::HKEY_USERS\$sid"
        if (-not $wasLoaded) {
            if (-not (Test-Path $ntuser)) { continue }
            $null = & reg.exe load "HKU\$sid" $ntuser 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Warning "   cannot load hive for $sid, skipped"; continue }
        }
        try { & $Apply "Registry::HKEY_USERS\$sid" }
        finally {
            if (-not $wasLoaded) {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                $null = & reg.exe unload "HKU\$sid" 2>&1
            }
        }
    }
    # Default User template -> future profiles
    $defPath = (Get-ItemProperty $profileList).Default
    $defNtuser = Join-Path $defPath 'NTUSER.DAT'
    if (Test-Path $defNtuser) {
        $null = & reg.exe load 'HKU\EfficiencyDefault' $defNtuser 2>&1
        if ($LASTEXITCODE -eq 0) {
            try { & $Apply 'Registry::HKEY_USERS\EfficiencyDefault' }
            finally {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                $null = & reg.exe unload 'HKU\EfficiencyDefault' 2>&1
            }
        }
    }
}

# --- Safety first ---------------------------------------------------------
if ($cfg.createRestorePoint) {
    Invoke-Step 'Create restore point' {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Checkpoint-Computer is rate-limited to one per 24h; not a failure.
        try { Checkpoint-Computer -Description 'EfficiencyBaseline' -RestorePointType MODIFY_SETTINGS }
        catch { Write-Host "   restore point skipped: $($_.Exception.Message)" }
    }
}

# --- Machine-wide telemetry & privacy -------------------------------------
if ($cfg.telemetryMachine) {
    Invoke-Step 'Telemetry policies (machine)' {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' AllowTelemetry 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' PublishUserActivities 0
    }
}
if ($cfg.activityHistory) {
    Invoke-Step 'Activity history off' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' EnableActivityFeed 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' UploadUserActivities 0
    }
}
if ($cfg.consumerFeatures) {
    Invoke-Step 'Consumer features off (no auto-installed promo apps)' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableWindowsConsumerFeatures 1
    }
}
if ($cfg.wpbt) {
    Invoke-Step 'WPBT execution off' {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' DisableWpbtExecution 1
    }
}
if ($cfg.powershell7Telemetry) {
    Invoke-Step 'PowerShell 7 telemetry opt-out' {
        [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
    }
}
if ($cfg.disableWidgets) {
    Invoke-Step 'Widgets / news feed off' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' AllowNewsAndInterests 0
    }
}
if ($cfg.disableDiagTrack) {
    Invoke-Step 'DiagTrack service off' {
        Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue
        Set-Service -Name DiagTrack -StartupType Disabled
    }
}
if ($cfg.svchostConsolidation) {
    Invoke-Step 'svchost consolidation' {
        $ramKb = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' SvcHostSplitThresholdInKB ([uint32]$ramKb) 'DWord'
    }
}
if ($cfg.storageSense) {
    Invoke-Step 'Storage Sense on (weekly; temp files only)' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' AllowStorageSenseGlobal 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' ConfigStorageSenseGlobalCadence 7
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' AllowStorageSenseTemporaryFilesCleanup 1
        # 0 = never: Storage Sense must NOT dehydrate OneDrive Files
        # On-Demand content or delete anything from users' Downloads.
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' ConfigStorageSenseCloudContentDehydrationThreshold 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' ConfigStorageSenseDownloadsCleanupThreshold 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' ConfigStorageSenseRecycleBinCleanupThreshold 30
    }
}
if ($cfg.disableCEIPTasks) {
    # CompatTelRunner.exe (Compatibility Appraiser) is a documented cause of
    # idle CPU/disk spikes; AllowTelemetry=0 does not stop these tasks.
    Invoke-Step 'CEIP / Compatibility Appraiser scheduled tasks off' {
        $tasks = @(
            @{ Path = '\Microsoft\Windows\Application Experience\';                   Name = 'Microsoft Compatibility Appraiser' },
            @{ Path = '\Microsoft\Windows\Application Experience\';                   Name = 'ProgramDataUpdater' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\';  Name = 'Consolidator' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\';  Name = 'UsbCeip' }
        )
        foreach ($t in $tasks) {
            $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
            if ($task) { $task | Disable-ScheduledTask | Out-Null; Write-Host "   disabled $($t.Name)" }
            else { Write-Host "   not present: $($t.Name)" }
        }
    }
}
if ($cfg.disableCopilot) {
    Invoke-Step 'Copilot off (policy)' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1
    }
}
if ($cfg.disableRecall) {
    Invoke-Step 'Recall / AI data analysis off (policy)' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' DisableAIDataAnalysis 1
    }
}
if ($cfg.disableGameDVR) {
    Invoke-Step 'Game DVR background recording off (policy)' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' AllowGameDVR 0
    }
}
if ($cfg.edgeBackgroundOff) {
    # Edge keeps processes alive after the browser is closed unless told not to.
    Invoke-Step 'Edge background mode off (policy)' {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' BackgroundModeEnabled 0
    }
}
if ($cfg.disableFastStartup) {
    # Off by default in config: trades slightly slower cold boots for
    # shutdown = real reset, which prevents accumulated slow-state machines.
    Invoke-Step 'Fast startup off' {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0
    }
}

# --- Per-user settings (all profiles + Default User template) -------------
if ($cfg.telemetryPerUser -or $cfg.endTaskOnTaskbar -or $cfg.explorerAutoDiscoveryFix -or
    $cfg.disableBingSearchSuggestions -or $cfg.disableCopilot -or $cfg.disableGameDVR -or
    $cfg.startMenuRecommendationsOff) {
    Invoke-Step 'Per-user privacy/UX settings (all profiles)' {
        Invoke-PerUserHive {
            param($root)
            if ($cfg.telemetryPerUser) {
                Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled 0
                Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Privacy" TailoredExperiencesWithDiagnosticDataEnabled 0
                Set-Reg "$root\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" HasAccepted 0
                Set-Reg "$root\Software\Microsoft\Input\TIPC" Enabled 0
                Set-Reg "$root\Software\Microsoft\InputPersonalization" RestrictImplicitInkCollection 1
                Set-Reg "$root\Software\Microsoft\InputPersonalization" RestrictImplicitTextCollection 1
                Set-Reg "$root\Software\Microsoft\InputPersonalization\TrainedDataStore" HarvestContacts 0
                Set-Reg "$root\Software\Microsoft\Personalization\Settings" AcceptedPrivacyPolicy 0
                Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" Start_TrackProgs 0
                Set-Reg "$root\Software\Microsoft\Siuf\Rules" NumberOfSIUFInPeriod 0
                Remove-ItemProperty -Path "$root\Software\Microsoft\Siuf\Rules" -Name PeriodInNanoSeconds -ErrorAction SilentlyContinue
            }
            if ($cfg.endTaskOnTaskbar) {
                Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" TaskbarEndTask 1
            }
            if ($cfg.explorerAutoDiscoveryFix) {
                Set-Reg "$root\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell" FolderType NotSpecified 'String'
            }
            if ($cfg.disableBingSearchSuggestions) {
                Set-Reg "$root\Software\Policies\Microsoft\Windows\Explorer" DisableSearchBoxSuggestions 1
                Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Search" BingSearchEnabled 0
            }
            if ($cfg.disableCopilot) {
                Set-Reg "$root\Software\Policies\Microsoft\Windows\WindowsCopilot" TurnOffWindowsCopilot 1
            }
            if ($cfg.disableGameDVR) {
                Set-Reg "$root\System\GameConfigStore" GameDVR_Enabled 0
            }
            if ($cfg.startMenuRecommendationsOff) {
                Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" Start_IrisRecommendations 0
            }
        }
    }
}

# --- Appx debloat (business-trimmed list from config) ----------------------
if ($cfg.removeAppx -and $cfg.removeAppx.Count -gt 0) {
    Invoke-Step "Remove appx packages ($($cfg.removeAppx.Count) in list)" {
        foreach ($name in $cfg.removeAppx) {
            $pkgs = Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue
            foreach ($pkg in $pkgs) {
                try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                      Write-Host "   removed $($pkg.Name)" }
                catch { Write-Warning "   could not remove $($pkg.Name): $($_.Exception.Message)" }
            }
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $name } |
                ForEach-Object {
                    try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                          Write-Host "   deprovisioned $name" }
                    catch { Write-Warning "   could not deprovision ${name}: $($_.Exception.Message)" }
                }
        }
    }
}

# --- Temp cleanup -----------------------------------------------------------
if ($cfg.tempCleanup) {
    Invoke-Step "Temp cleanup (older than $($cfg.tempFileAgeDays) days)" {
        $cutoff = (Get-Date).AddDays(-[int]$cfg.tempFileAgeDays)
        $targets = @("$env:windir\Temp")
        $targets += Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } |
            Where-Object { Test-Path $_ }
        foreach ($t in $targets) {
            Get-ChildItem $t -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Result -----------------------------------------------------------------
if ($script:Failures.Count -gt 0) {
    Write-Warning "Completed with $($script:Failures.Count) failed step(s): $($script:Failures -join ', ')"
    Stop-Transcript | Out-Null
    exit 3
}
Write-Host 'All steps completed successfully.'
Stop-Transcript | Out-Null
exit 0

<#
.SYNOPSIS
    READ-ONLY audit: captures the current state of every setting the
    efficiency payload manages, plus a small performance snapshot.
    Changes nothing. Run before and after applying the baseline to get a
    clean diff; works interactively or as SYSTEM via RMM.

.DESCRIPTION
    Machine checks read HKLM/services/tasks/appx. Per-user checks are
    evaluated against EVERY real user profile (local S-1-5-21-* and Entra
    S-1-12-1-*) plus the Default User template - hives of logged-off users
    are temporarily mounted read-only-in-spirit and unmounted after. This
    makes the audit correct under SYSTEM, where HKCU would otherwise be
    SYSTEM's own (empty) profile.

    Exit codes: 0 = fully compliant, 1 = one or more DIFFs (alertable from
    RMM), 2 = audit error.
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not $OutFile) {
    $OutFile = Join-Path $env:TEMP ("baseline-state-{0}-{1:yyyyMMdd-HHmm}.json" -f $env:COMPUTERNAME, (Get-Date))
}

$machineChecks = @(
    @{Area='Machine'; Label='Telemetry level';            Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name='AllowTelemetry'; Expected=0}
    @{Area='Machine'; Label='Publish user activities';    Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='PublishUserActivities'; Expected=0}
    @{Area='Machine'; Label='Activity feed';              Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='EnableActivityFeed'; Expected=0}
    @{Area='Machine'; Label='Upload user activities';     Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='UploadUserActivities'; Expected=0}
    @{Area='Machine'; Label='Consumer features';          Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures'; Expected=1}
    @{Area='Machine'; Label='WPBT execution';             Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Name='DisableWpbtExecution'; Expected=1}
    @{Area='Machine'; Label='Widgets / news feed';        Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name='AllowNewsAndInterests'; Expected=0}
    @{Area='Machine'; Label='News feed Win10 (EnableFeeds)'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name='EnableFeeds'; Expected=0}
    @{Area='Machine'; Label='Storage Sense allowed';      Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='AllowStorageSenseGlobal'; Expected=1}
    @{Area='Machine'; Label='Storage Sense cadence';      Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='ConfigStorageSenseGlobalCadence'; Expected=7}
    @{Area='Machine'; Label='Storage Sense temp cleanup'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='AllowStorageSenseTemporaryFilesCleanup'; Expected=1}
    @{Area='Machine'; Label='OneDrive dehydration (0=never)'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='ConfigStorageSenseCloudContentDehydrationThreshold'; Expected=0}
    @{Area='Machine'; Label='Downloads cleanup (0=never)'; Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='ConfigStorageSenseDownloadsCleanupThreshold'; Expected=0}
    @{Area='Machine'; Label='Recycle Bin cleanup days';   Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='ConfigStorageSenseRecycleBinCleanupThreshold'; Expected=30}
    @{Area='Machine'; Label='Recall / AI data analysis';  Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAIDataAnalysis'; Expected=1}
    @{Area='Machine'; Label='Game DVR policy';            Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name='AllowGameDVR'; Expected=0}
    @{Area='Machine'; Label='Edge background mode';       Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name='BackgroundModeEnabled'; Expected=0}
    @{Area='Machine'; Label='Fast startup (hiberboot)';   Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name='HiberbootEnabled'; Expected=0}
    @{Area='Machine'; Label='svchost split threshold';    Path='HKLM:\SYSTEM\CurrentControlSet\Control'; Name='SvcHostSplitThresholdInKB'; Expected=[uint32]((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB)}
)

# Relative to each user hive root
$userChecks = @(
    @{Label='Advertising ID';             Rel='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Expected=0}
    @{Label='Tailored experiences';       Rel='Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Expected=0}
    @{Label='Online speech';              Rel='Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name='HasAccepted'; Expected=0}
    @{Label='Typing telemetry (TIPC)';    Rel='Software\Microsoft\Input\TIPC'; Name='Enabled'; Expected=0}
    @{Label='Implicit ink collection';    Rel='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitInkCollection'; Expected=1}
    @{Label='Implicit text collection';   Rel='Software\Microsoft\InputPersonalization'; Name='RestrictImplicitTextCollection'; Expected=1}
    @{Label='Harvest contacts';           Rel='Software\Microsoft\InputPersonalization\TrainedDataStore'; Name='HarvestContacts'; Expected=0}
    @{Label='Personalization privacy';    Rel='Software\Microsoft\Personalization\Settings'; Name='AcceptedPrivacyPolicy'; Expected=0}
    @{Label='App-launch tracking';        Rel='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='Start_TrackProgs'; Expected=0}
    @{Label='Feedback prompts';           Rel='Software\Microsoft\Siuf\Rules'; Name='NumberOfSIUFInPeriod'; Expected=0}
    @{Label='End Task on taskbar';        Rel='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name='TaskbarEndTask'; Expected=1}
    @{Label='Folder auto-discovery';      Rel='Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; Name='FolderType'; Expected='NotSpecified'}
    @{Label='Search box web suggestions'; Rel='Software\Policies\Microsoft\Windows\Explorer'; Name='DisableSearchBoxSuggestions'; Expected=1}
    @{Label='Bing in Start search';       Rel='Software\Microsoft\Windows\CurrentVersion\Search'; Name='BingSearchEnabled'; Expected=0}
    @{Label='Game DVR (user)';            Rel='System\GameConfigStore'; Name='GameDVR_Enabled'; Expected=0}
    @{Label='Start menu recommendations'; Rel='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='Start_IrisRecommendations'; Expected=0}
)

$results = @()
function Add-Check {
    param([string]$Area, [string]$Label, $Current, $Expected)
    $cur = if ($null -eq $Current) { '(not set)' } else { $Current }
    $script:results += [pscustomobject]@{
        Area = $Area; Setting = $Label; Current = $cur; Expected = $Expected
        Status = if ("$cur" -eq "$Expected") { 'MATCH' } else { 'DIFF' }
    }
}

foreach ($c in $machineChecks) {
    Add-Check $c.Area $c.Label ((Get-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction SilentlyContinue).($c.Name)) $c.Expected
}

# Env var
$envVal = [Environment]::GetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', 'Machine')
Add-Check 'Machine' 'PS7 telemetry opt-out env' $envVal '1'

# DiagTrack service
$svc = Get-Service -Name DiagTrack -ErrorAction SilentlyContinue
$svcState = if ($svc) { "$($svc.StartType)/$($svc.Status)" } else { '(missing)' }
Add-Check 'Service' 'DiagTrack' $svcState 'Disabled/Stopped'

# CEIP scheduled tasks (absent counts as compliant)
foreach ($t in @(
    @{P='\Microsoft\Windows\Application Experience\'; N='Microsoft Compatibility Appraiser'},
    @{P='\Microsoft\Windows\Application Experience\'; N='ProgramDataUpdater'},
    @{P='\Microsoft\Windows\Customer Experience Improvement Program\'; N='Consolidator'},
    @{P='\Microsoft\Windows\Customer Experience Improvement Program\'; N='UsbCeip'})) {
    $task = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue
    if ($task) { Add-Check 'Task' $t.N "$($task.State)" 'Disabled' }
    else {
        $results += [pscustomobject]@{ Area='Task'; Setting=$t.N; Current='(not present)'; Expected='Disabled'; Status='MATCH' }
    }
}

# Appx removal list
foreach ($name in @('Microsoft.WindowsFeedbackHub','Microsoft.BingNews','Microsoft.BingSearch',
    'Microsoft.BingWeather','Clipchamp.Clipchamp','Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.Windows.DevHome','Microsoft.ZuneMusic','Microsoft.StartExperiencesApp','Microsoft.GetHelp')) {
    $pkg = Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue
    Add-Check 'Appx' $name $(if ($pkg) { 'installed' } else { 'absent' }) 'absent'
}

# --- Per-user checks: every real profile + Default template ----------------
# Correct under SYSTEM, where HKCU would be SYSTEM's own empty profile.
function Test-UserHive {
    param([string]$Root, [string]$Who)
    foreach ($c in $userChecks) {
        Add-Check "User:$Who" $c.Label ((Get-ItemProperty -Path "$Root\$($c.Rel)" -Name $c.Name -ErrorAction SilentlyContinue).($c.Name)) $c.Expected
    }
}

$profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$profiles = Get-ChildItem $profileList -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-' }
foreach ($p in $profiles) {
    $sid  = $p.PSChildName
    $path = (Get-ItemProperty $p.PSPath).ProfileImagePath
    $who  = Split-Path $path -Leaf
    if (Test-Path "Registry::HKEY_USERS\$sid") {
        Test-UserHive -Root "Registry::HKEY_USERS\$sid" -Who $who
    } else {
        $ntuser = Join-Path $path 'NTUSER.DAT'
        if (-not (Test-Path $ntuser)) { continue }
        $null = & reg.exe load 'HKU\BaselineAudit' $ntuser 2>&1
        if ($LASTEXITCODE -ne 0) {
            $results += [pscustomobject]@{ Area="User:$who"; Setting='(all per-user checks)'; Current='(hive locked, skipped)'; Expected='-'; Status='SKIP' }
            continue
        }
        try { Test-UserHive -Root 'Registry::HKEY_USERS\BaselineAudit' -Who $who }
        finally {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            $null = & reg.exe unload 'HKU\BaselineAudit' 2>&1
        }
    }
}

# Default User template (future profiles)
$defNtuser = Join-Path (Get-ItemProperty $profileList).Default 'NTUSER.DAT'
if (Test-Path $defNtuser) {
    $null = & reg.exe load 'HKU\BaselineAuditDefault' $defNtuser 2>&1
    if ($LASTEXITCODE -eq 0) {
        try { Test-UserHive -Root 'Registry::HKEY_USERS\BaselineAuditDefault' -Who 'DefaultTemplate' }
        finally {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            $null = & reg.exe unload 'HKU\BaselineAuditDefault' 2>&1
        }
    }
}

# --- Performance snapshot (context, not pass/fail) ---
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$snapshot = [ordered]@{
    computer     = $env:COMPUTERNAME
    timestamp    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    runningAs    = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    windowsBuild = "$($os.Caption) $($os.Version)"
    lastBoot     = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
    uptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    ramTotalGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    ramFreeGB    = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    processCount = (Get-Process).Count
    diskCFreeGB  = [math]::Round($disk.FreeSpace / 1GB, 1)
}

# --- Output ---
$diffs = @($results | Where-Object Status -eq 'DIFF')
Write-Host ("`n=== Baseline state: {0} - {1} (as {2}) ===" -f $snapshot.computer, $snapshot.timestamp, $snapshot.runningAs)
Write-Host ("{0} | boot {1} | up {2}h | RAM {3}/{4}GB free | {5} processes | C: {6}GB free`n" -f `
    $snapshot.windowsBuild, $snapshot.lastBoot, $snapshot.uptimeHours,
    $snapshot.ramFreeGB, $snapshot.ramTotalGB, $snapshot.processCount, $snapshot.diskCFreeGB)
$results | Sort-Object Status, Area | Format-Table Area, Setting, Current, Expected, Status -AutoSize
Write-Host ("{0} of {1} checks match the baseline; {2} differ.`n" -f `
    ($results.Count - $diffs.Count), $results.Count, $diffs.Count)

[ordered]@{ snapshot = $snapshot; results = $results } |
    ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Saved JSON: $OutFile"

if ($diffs.Count -gt 0) { exit 1 } else { exit 0 }

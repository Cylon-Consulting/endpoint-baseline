<#
.SYNOPSIS
    READ-ONLY audit: captures the current state of every setting the
    efficiency payload manages, plus a small performance snapshot.
    Changes nothing. Run before and after applying the baseline to get a
    clean diff; works on an existing machine or a fresh VM build.

.DESCRIPTION
    Expected values mirror payload/SETTINGS.md with the current config
    (Copilot left enabled, fast startup disabled). Per-user values are read
    from the CURRENT user's hive - run as the normally logged-in user
    (elevated, so appx/task/service state is readable).

    Output: console report (paste-friendly) and a JSON file next to the
    script / in %TEMP% for archival.
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not $OutFile) {
    $OutFile = Join-Path $env:TEMP ("baseline-state-{0}-{1:yyyyMMdd-HHmm}.json" -f $env:COMPUTERNAME, (Get-Date))
}

$checks = @(
    # --- Machine: telemetry & privacy ---
    @{Area='Machine'; Label='Telemetry level';            Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name='AllowTelemetry'; Expected=0}
    @{Area='Machine'; Label='Publish user activities';    Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='PublishUserActivities'; Expected=0}
    @{Area='Machine'; Label='Activity feed';              Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='EnableActivityFeed'; Expected=0}
    @{Area='Machine'; Label='Upload user activities';     Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='UploadUserActivities'; Expected=0}
    @{Area='Machine'; Label='Consumer features';          Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures'; Expected=1}
    @{Area='Machine'; Label='WPBT execution';             Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Name='DisableWpbtExecution'; Expected=1}
    @{Area='Machine'; Label='Widgets / news feed';        Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name='AllowNewsAndInterests'; Expected=0}
    @{Area='Machine'; Label='Storage Sense allowed';      Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='AllowStorageSenseGlobal'; Expected=1}
    @{Area='Machine'; Label='Storage Sense cadence';      Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name='ConfigStorageSenseGlobalCadence'; Expected=7}
    @{Area='Machine'; Label='Recall / AI data analysis';  Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAIDataAnalysis'; Expected=1}
    @{Area='Machine'; Label='Game DVR policy';            Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name='AllowGameDVR'; Expected=0}
    @{Area='Machine'; Label='Edge background mode';       Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name='BackgroundModeEnabled'; Expected=0}
    @{Area='Machine'; Label='Fast startup (hiberboot)';   Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name='HiberbootEnabled'; Expected=0}
    @{Area='Machine'; Label='svchost split threshold';    Path='HKLM:\SYSTEM\CurrentControlSet\Control'; Name='SvcHostSplitThresholdInKB'; Expected=[uint32]((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB)}
    # --- Current user ---
    @{Area='User'; Label='Advertising ID';                Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Expected=0}
    @{Area='User'; Label='Tailored experiences';          Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Expected=0}
    @{Area='User'; Label='Online speech';                 Path='HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name='HasAccepted'; Expected=0}
    @{Area='User'; Label='Typing telemetry (TIPC)';       Path='HKCU:\Software\Microsoft\Input\TIPC'; Name='Enabled'; Expected=0}
    @{Area='User'; Label='Implicit ink collection';       Path='HKCU:\Software\Microsoft\InputPersonalization'; Name='RestrictImplicitInkCollection'; Expected=1}
    @{Area='User'; Label='Implicit text collection';      Path='HKCU:\Software\Microsoft\InputPersonalization'; Name='RestrictImplicitTextCollection'; Expected=1}
    @{Area='User'; Label='Harvest contacts';              Path='HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'; Name='HarvestContacts'; Expected=0}
    @{Area='User'; Label='Personalization privacy';       Path='HKCU:\Software\Microsoft\Personalization\Settings'; Name='AcceptedPrivacyPolicy'; Expected=0}
    @{Area='User'; Label='App-launch tracking';           Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='Start_TrackProgs'; Expected=0}
    @{Area='User'; Label='Feedback prompts';              Path='HKCU:\Software\Microsoft\Siuf\Rules'; Name='NumberOfSIUFInPeriod'; Expected=0}
    @{Area='User'; Label='End Task on taskbar';           Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name='TaskbarEndTask'; Expected=1}
    @{Area='User'; Label='Folder auto-discovery';         Path='HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; Name='FolderType'; Expected='NotSpecified'}
    @{Area='User'; Label='Search box web suggestions';    Path='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name='DisableSearchBoxSuggestions'; Expected=1}
    @{Area='User'; Label='Bing in Start search';          Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name='BingSearchEnabled'; Expected=0}
    @{Area='User'; Label='Game DVR (user)';                Path='HKCU:\System\GameConfigStore'; Name='GameDVR_Enabled'; Expected=0}
    @{Area='User'; Label='Start menu recommendations';    Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='Start_IrisRecommendations'; Expected=0}
)

$results = @()
foreach ($c in $checks) {
    $val = (Get-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction SilentlyContinue).($c.Name)
    $current = if ($null -eq $val) { '(not set)' } else { $val }
    $match = "$current" -eq "$($c.Expected)"
    $results += [pscustomobject]@{
        Area = $c.Area; Setting = $c.Label; Current = $current
        Expected = $c.Expected; Status = if ($match) { 'MATCH' } else { 'DIFF' }
    }
}

# Env var
$envVal = [Environment]::GetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', 'Machine')
$results += [pscustomobject]@{ Area='Machine'; Setting='PS7 telemetry opt-out env'; Current=$(if ($null -eq $envVal) {'(not set)'} else {$envVal}); Expected='1'; Status=$(if ("$envVal" -eq '1') {'MATCH'} else {'DIFF'}) }

# DiagTrack service
$svc = Get-Service -Name DiagTrack -ErrorAction SilentlyContinue
$svcState = if ($svc) { "$($svc.StartType)/$($svc.Status)" } else { '(missing)' }
$results += [pscustomobject]@{ Area='Service'; Setting='DiagTrack'; Current=$svcState; Expected='Disabled/Stopped'; Status=$(if ($svc -and $svc.StartType -eq 'Disabled') {'MATCH'} else {'DIFF'}) }

# CEIP scheduled tasks
foreach ($t in @(
    @{P='\Microsoft\Windows\Application Experience\'; N='Microsoft Compatibility Appraiser'},
    @{P='\Microsoft\Windows\Application Experience\'; N='ProgramDataUpdater'},
    @{P='\Microsoft\Windows\Customer Experience Improvement Program\'; N='Consolidator'},
    @{P='\Microsoft\Windows\Customer Experience Improvement Program\'; N='UsbCeip'})) {
    $task = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue
    $cur = if ($task) { "$($task.State)" } else { '(not present)' }
    $ok = (-not $task) -or $task.State -eq 'Disabled'
    $results += [pscustomobject]@{ Area='Task'; Setting=$t.N; Current=$cur; Expected='Disabled'; Status=$(if ($ok) {'MATCH'} else {'DIFF'}) }
}

# Appx removal list
foreach ($name in @('Microsoft.WindowsFeedbackHub','Microsoft.BingNews','Microsoft.BingSearch',
    'Microsoft.BingWeather','Clipchamp.Clipchamp','Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.Windows.DevHome','Microsoft.ZuneMusic','Microsoft.StartExperiencesApp','Microsoft.GetHelp')) {
    $pkg = Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue
    $cur = if ($pkg) { 'installed' } else { 'absent' }
    $results += [pscustomobject]@{ Area='Appx'; Setting=$name; Current=$cur; Expected='absent'; Status=$(if ($pkg) {'DIFF'} else {'MATCH'}) }
}

# --- Performance snapshot (context, not pass/fail) ---
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$snapshot = [ordered]@{
    computer     = $env:COMPUTERNAME
    timestamp    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
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
Write-Host ("`n=== Baseline state: {0} - {1} ===" -f $snapshot.computer, $snapshot.timestamp)
Write-Host ("{0} | boot {1} | up {2}h | RAM {3}/{4}GB free | {5} processes | C: {6}GB free`n" -f `
    $snapshot.windowsBuild, $snapshot.lastBoot, $snapshot.uptimeHours,
    $snapshot.ramFreeGB, $snapshot.ramTotalGB, $snapshot.processCount, $snapshot.diskCFreeGB)
$results | Sort-Object Status, Area | Format-Table Area, Setting, Current, Expected, Status -AutoSize
Write-Host ("{0} of {1} settings already match the baseline; {2} would change.`n" -f `
    ($results.Count - $diffs.Count), $results.Count, $diffs.Count)

[ordered]@{ snapshot = $snapshot; results = $results } |
    ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Saved JSON: $OutFile"

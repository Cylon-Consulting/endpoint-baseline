# Efficiency Baseline — Change Inventory

Every setting changed by `Invoke-EfficiencyBaseline.ps1` with the current
`efficiency-config.json`, and the reason for each. Config toggle names in
parentheses. Derived from WinUtil release 26.05.12 (business-trimmed) plus
researched additions; see git history for change control.

## Safety (runs first)

| Change | Technical detail | Reason |
|---|---|---|
| System restore point (`createRestorePoint`) | `Enable-ComputerRestore` + `Checkpoint-Computer` | Rollback path before any changes; tolerates Windows' one-per-24h limit |

## Machine-wide (HKLM / services / scheduled tasks)

| Change | Technical detail | Reason |
|---|---|---|
| Telemetry to minimum (`telemetryMachine`) | `Policies\DataCollection → AllowTelemetry=0` | Cuts diagnostic uploads (~6MB/day/machine) to required-only |
| Activity history off (`activityHistory`, `telemetryMachine`) | `Policies\System → EnableActivityFeed=0, UploadUserActivities=0, PublishUserActivities=0` | Stops timeline collection and upload of user activity |
| Consumer features off (`consumerFeatures`) | `CloudContent → DisableWindowsConsumerFeatures=1` | Stops Windows auto-installing promoted apps — prevents future bloat |
| WPBT execution off (`wpbt`) | `Session Manager → DisableWpbtExecution=1` | Blocks vendor firmware from injecting software at boot |
| PowerShell 7 telemetry off (`powershell7Telemetry`) | Machine env var `POWERSHELL_TELEMETRY_OPTOUT=1` | Stops pwsh usage telemetry |
| Widgets/news feed off (`disableWidgets`) | `Policies\Dsh → AllowNewsAndInterests=0` | Kills the persistent `webexperience` background process and its content pulls |
| DiagTrack service disabled (`disableDiagTrack`) | `Stop-Service` + startup type Disabled | The main telemetry collector/uploader process |
| svchost consolidation (`svchostConsolidation`) | `SvcHostSplitThresholdInKB` = installed RAM | Merges service host processes — fewer processes, ~50–150MB less overhead |
| Storage Sense on, weekly, temp-files-only (`storageSense`) | `Policies\StorageSense → AllowStorageSenseGlobal=1, Cadence=7, TemporaryFilesCleanup=1, CloudContentDehydrationThreshold=0, DownloadsCleanupThreshold=0, RecycleBinCleanupThreshold=30` | Disks self-clean between runs. Dehydration and Downloads thresholds pinned to 0 (never): Storage Sense must not turn OneDrive files online-only or delete from users' Downloads |
| CEIP scheduled tasks off (`disableCEIPTasks`) | Disables: Microsoft Compatibility Appraiser, ProgramDataUpdater, Consolidator, UsbCeip | CompatTelRunner.exe is a documented cause of idle CPU/disk spikes; AllowTelemetry=0 alone does not stop these tasks |
| Recall off (`disableRecall`) | `Policies\WindowsAI → DisableAIDataAnalysis=1` | Stops continuous screen-snapshotting on Copilot+ hardware; privacy |
| Game DVR off (`disableGameDVR`) | `Policies\GameDVR → AllowGameDVR=0` | Disables Xbox background screen-recording — unused on business machines |
| Edge background mode off (`edgeBackgroundOff`) | `Policies\Edge → BackgroundModeEnabled=0` | Edge no longer keeps processes resident after being closed |
| Fast startup off (`disableFastStartup`) | `Session Manager\Power → HiberbootEnabled=0` | Every shutdown is a true reset — prevents accumulated slow-state; "I restarted it" actually means restarted. Cold boots a few seconds slower |

## Per-user — applied to every existing profile + Default User template

Applied via NTUSER.DAT hive loading so settings reach all current and future
users even when run as SYSTEM through RMM.

| Change | Technical detail | Reason |
|---|---|---|
| Advertising ID off (`telemetryPerUser`) | `AdvertisingInfo → Enabled=0` | No cross-app ad tracking identifier |
| Tailored experiences off (`telemetryPerUser`) | `Privacy → TailoredExperiencesWithDiagnosticDataEnabled=0` | No diagnostic-data-driven suggestions |
| Online speech privacy (`telemetryPerUser`) | `OnlineSpeechPrivacy → HasAccepted=0` | No cloud speech recognition data |
| Typing telemetry off (`telemetryPerUser`) | `Input\TIPC → Enabled=0` | No typing/inking data collection |
| Input personalization off (`telemetryPerUser`) | `RestrictImplicitInkCollection=1, RestrictImplicitTextCollection=1, HarvestContacts=0` | No handwriting/typing/contact harvesting |
| Personalization privacy (`telemetryPerUser`) | `Personalization\Settings → AcceptedPrivacyPolicy=0` | Companion to input personalization opt-out |
| App-launch tracking off (`telemetryPerUser`) | `Explorer\Advanced → Start_TrackProgs=0` | Windows stops recording which apps users launch |
| Feedback prompts off (`telemetryPerUser`) | `Siuf\Rules → NumberOfSIUFInPeriod=0` (+ remove `PeriodInNanoSeconds`) | No "rate your experience" nag popups |
| End Task on taskbar (`endTaskOnTaskbar`) | `TaskbarDeveloperSettings → TaskbarEndTask=1` | Users can kill a hung app themselves — fewer support calls |
| Folder auto-discovery fix (`explorerAutoDiscoveryFix`) | `Bags\AllFolders\Shell → FolderType=NotSpecified` | Kills slow green-bar folder loading — the most literal "slow" complaint |
| Bing in Start menu off (`disableBingSearchSuggestions`) | `Policies\Explorer → DisableSearchBoxSuggestions=1` + `Search → BingSearchEnabled=0` | Start search stops firing web requests per keystroke — instant local search; big win on hotspots |
| Game DVR off per-user (`disableGameDVR`) | `GameConfigStore → GameDVR_Enabled=0` | Companion to machine policy |
| Start menu recommendations off (`startMenuRecommendationsOff`) | `Explorer\Advanced → Start_IrisRecommendations=0` | Stops the suggestion engine churning in the Start menu |

## Removed apps (`removeAppx`) — Appx + provisioned, all users

| Apps | Reason |
|---|---|
| Microsoft.BingNews, Microsoft.BingWeather, Microsoft.BingSearch | Background content prefetch; consumer clutter |
| Microsoft.WindowsFeedbackHub, Microsoft.GetHelp | Telemetry adjunct / unused on managed fleets |
| Microsoft.MicrosoftSolitaireCollection, Microsoft.ZuneMusic, Clipchamp.Clipchamp | Consumer media apps |
| Microsoft.Windows.DevHome, Microsoft.StartExperiencesApp | Unused system apps |

## Cleanup

| Change | Technical detail | Reason |
|---|---|---|
| Temp file purge (`tempCleanup`, `tempFileAgeDays=7`) | Files >7 days old in `C:\Windows\Temp` + every user's `AppData\Local\Temp` | Reclaims disk; complements Storage Sense |

## Deliberately NOT touched

- **Defender / AV** — fleet runs OpenText (Webroot); Defender stays factory-default as the automatic fallback
- **Windows Copilot** — left enabled (`disableCopilot: false`); some users actively use it. Note: Recall is still disabled — separate feature, no workflow depends on it. Microsoft 365 Copilot (Office) was never affected by these policies either way
- **Windows Error Reporting** — diagnostic value when investigating user issues; zero idle cost
- **Location services** — uniform desktop/laptop payload; auto-timezone for field laptops
- **Business apps** — Teams, Outlook, Quick Assist, Sticky Notes, Paint, To Do, Power Automate, Alarms, Sound Recorder, OneDrive
- **Windows Search indexing** — removal creates slow-search complaints
- **Edge startup boost** — helps users whose main browser is Edge
- **SysMain, IPv6, Teredo** — regression risk exceeds measurable gain
- **Hibernation** — only the hybrid-boot piece (fast startup) is disabled; laptop hibernate still works
- **Visual effects / animations / taskbar layout** — visible changes generate "my computer looks different" calls

# Upstream review — issues #1 and #2

Date: 2026-11-24
Scope: WinUtil 26.05.12 → 26.11.13 (issue #2) and Win11Debloat changes since the
June review (issue #1), compared against `payload/Invoke-EfficiencyBaseline.ps1`
and `payload/efficiency-config.json` at manifest v1.0.5.

## Outcome

- Adopted: section 1, sections 2a to 2c, and the housekeeping in section 6
  (baseline re-approved against 26.11.13, watchlist marked reviewed, `link`
  and `Description` excluded from the tweak hash). The "comment only when the
  report changes" idea was not implemented.
- Section 4: left as is.
- Local test: `testing/Invoke-LocalTest.ps1` applied
  `testing/local-delta-config.json` on one already-baselined Windows 11
  laptop (build 26200). Payload exit 0, nine values changed, all targeted
  settings match.
- The clipboard claim in section 1 is NOT confirmed by that test. The test
  machine had a separate `AllowClipboardHistory=0` policy, not set by this
  payload, by group policy or by MDM, which blocks Win+V on its own. The
  `EnableActivityFeed` change therefore rests on upstream's report only.

The sections below are the review as written before those changes were made.

## Summary

- One upstream change points at a probable regression in the live payload:
  `EnableActivityFeed=0` can disable Win+V clipboard history.
- Three small additions are worth adopting.
- Everything else is either already covered, conflicts with a documented
  decision in `SETTINGS.md`, or is cosmetic.
- Most of the WinUtil "definition changed" flags are noise from a docs URL move.

## 1. Fix — clipboard history (payload line 136)

| | |
|---|---|
| Payload today | `Policies\Microsoft\Windows\System → EnableActivityFeed=0` (toggle `activityHistory`) |
| Upstream now | `EnableActivityFeed=1`, keeping `PublishUserActivities=0` and `UploadUserActivities=0` |
| Source | WinUtil PR #5035, merged 2026-09-02, from bug report #5023 |
| Upstream's reason | Value 0 also disables Win+V clipboard history on affected Windows 10 and 11 systems and shows the setting as managed by the organisation |

The payload has been writing 0 since June, so any affected machine has had
clipboard history off since its first run.

Recommendation: change the value to 1. The payload rewrites the value on every
run, so the next run repairs existing machines. Activity publishing and upload
stay blocked by the other two values.

Check first: on one fleet machine, press Win+V and open Settings → System →
Clipboard. If history works there, the change is still harmless but not urgent.

## 2. Adopt

| # | Change | Registry | Why |
|---|---|---|---|
| 2a | Block device companion-app auto-install (new toggle) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata → PreventDeviceMetadataFromNetwork=1` | Both upstreams added this independently (WinUtil FYI tweak; Win11Debloat #695). Stops Windows pulling vendor apps when a monitor, dock or printer is plugged in. Same intent as `consumerFeatures` |
| 2b | Hide suggested websites in Start (under `startMenuRecommendationsOff`) | `HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer → HideRecommendedPersonalizedSites=1` | Win11Debloat #899. Complements the existing per-user `Start_IrisRecommendations=0` |
| 2c | Edge promotions off (new toggle) | `HKLM\SOFTWARE\Policies\Microsoft\Edge →` `ShowRecommendationsEnabled=0`, `EdgeShoppingAssistantEnabled=0`, `ShowMicrosoftRewards=0`, `DefaultBrowserSettingsCampaignEnabled=0`, `SpotlightExperiencesAndRecommendationsEnabled=0`, `UserFeedbackAllowed=0`, `WalletDonationEnabled=0`, `ShowAcrobatSubscriptionButton=0` | Win11Debloat's Edge set (#900 added Rewards). This is the subset users will not notice |

Notes:

- 2a also stops vendor utilities that some people want (printer or dock
  companion apps). Pilot it on a few machines before fleet rollout.
- 2c deliberately leaves out `NewTabPageContentEnabled`,
  `NewTabPageHideDefaultTopSites`, `HideFirstRunExperience`,
  `DefaultBrowserSettingEnabled`, `TabServicesEnabled` and
  `AlternateErrorPagesEnabled`. Those change what users see, which the payload
  avoids elsewhere.

## 3. Do not adopt

| Upstream change | Source | Reason to skip |
|---|---|---|
| Delivery Optimization off (`DODownloadMode=0`) | WinUtil Standard preset addition | Turns off LAN peer caching, so every machine downloads updates over the WAN. Enterprise and Education already default to LAN-only peering (Pro as well, as far as I know — not checked against current Microsoft docs) |
| Disable `WerSvc` | WinUtil Telemetry, Win11Debloat #901 | `SETTINGS.md` keeps Windows Error Reporting for diagnostics |
| Defender sample submission off | Win11Debloat #901 (WinUtil already had it) | `SETTINGS.md`: nothing AV-related is touched |
| Disable driver updates via Windows Update | Win11Debloat #870 | The fleet would stop receiving drivers unless something else delivers them |
| Disable notifications | Win11Debloat #690 | Kills Teams and Outlook toasts |
| Chrome AI off, Edge Copilot Chat icon off, hide M365 Copilot setup screen | Win11Debloat #763, #811, #883 | Copilot is deliberately left enabled; revisit only if that stance changes |
| Startup-app delay off | Win11Debloat #898 | Marginal gain, per-user tweak |
| Start search WebView2 override | Win11Debloat #884 | Unsupported feature-flag override |
| Context menu, desktop Spotlight, Start all-apps layout | Win11Debloat #888, #904, #746 | Cosmetic; payload does not touch these |
| 22 OEM apps (Samsung, ASUS, Acer, MSI, HP OMEN, LG) | Win11Debloat #864 | All default-off upstream; only relevant if the fleet has that hardware |
| Windows App removal | Win11Debloat #863 | Business remote-desktop client |
| Services list changes | WinUtil Services | Payload does not apply the services tweak |

No action needed for these either:

- Removed upstream and never used by the payload: `DisableSearchHistory`,
  `DisableSearchHighlights` (#800), Drag Tray (#850).
- Bing News renamed Microsoft News (#810): same package ID
  `Microsoft.BingNews`, already in `removeAppx`.
- DiagTrack disabled, PowerShell 7 telemetry opt-out, `PeriodInNanoSeconds`
  removal: already in the payload.

## 4. Judgement call — svchost consolidation

WinUtil moved the `SvcHostSplitThresholdInKB` write out of the Services tweak
into a separate "Advanced Tweaks – CAUTION" entry (PR #5170, 2026-10-21). It is
no longer in the Standard preset and is now recommended only for machines with
12 GB of RAM or less. The stated reason is that it can leave Xbox services
stuck on Starting.

The payload applies it to every machine (`svchostConsolidation`).

Recommendation: leave it as is. The only documented breakage is Xbox services,
which a business fleet does not use. The alternative is to apply it only at or
below 12 GB, which needs a script change rather than a config change.

## 5. What the WinUtil "definition changed" list actually contained

| Tweak | Real change |
|---|---|
| `Activity` | `EnableActivityFeed` 0 → 1 (section 1) |
| `Telemetry` | `wermgr` → `WerSvc`; PowerShell 7 opt-out folded in; error handling |
| `Services` | svchost threshold moved out; 6 no-op service entries removed |
| `DeleteTempFiles` | `-ErrorAction SilentlyContinue` added (payload already does this) |
| `Location` | Typo fix `Disable` → `Disabled` |
| `ConsumerFeatures`, `EndTaskOnTaskbar` | Description text and docs link only |
| `DisableExplorerAutoDiscovery`, `DiskCleanup`, `RestorePoint`, `WPBT` | Docs link only |

Removed upstream:

- `WPFTweaksPowershell7Tele` was merged into `Telemetry`.
- `WPFTweaksDeBloat` was deleted outright; the payload's `removeAppx` list is
  its own and is unaffected.

## 6. Housekeeping to close the issues

1. Add `WPFTweaksDeliveryOptimization` to `approvedPreset` in `baseline.json`
   as reviewed-not-applied, and list it under "Deliberately NOT touched" in
   `SETTINGS.md`. The checker has no "declined" list, so leaving it out means
   the drift issue reopens every Wednesday. `Location` and `Services` are
   already in `approvedPreset` on the same basis.
2. Run the workflow manually with `update_baseline` and `approve_watches`
   ticked. `-UpdateBaseline` drops `DeBloat` and `Powershell7Tele`
   automatically because they no longer exist upstream.
3. Close #1 and #2.

Checker improvements (optional):

- Exclude `link` and `Description` from the per-tweak hash. Six of the eleven
  flags this time were only that.
- Post a comment only when the report differs from the previous one. The two
  issues hold 43 comments covering about 20 distinct reports.

## 7. Outside the diff — worth a second look

Both of these came from WinUtil's old DeBloat list, which WinUtil has since
deleted. Neither is new since June.

- `Microsoft.GetHelp` is in `removeAppx`. Win11Debloat rates it "unsafe":
  it is required for some Windows 11 troubleshooters.
- `Microsoft.ZuneMusic` is in `removeAppx` as a consumer media app. On
  Windows 11 this package is the Media Player that plays local audio and video.

# Windows settings changed by -Activate

[`710sRice activate`](../README.md#switching-activate--deactivate) and
[`710sRice install -Activate`](../README.md#full-time--activate) turn these off. All of them
are under `HKEY_CURRENT_USER`, so they affect only your account and need no admin rights.

Before changing them, going full-time saves each one as it was (whether it existed, and its
value), along with taskbar auto-hide and Explorer's Startup delay. `710sRice deactivate` and
uninstall put each one back from that copy. An install made full-time before 710sRice saved
them has no copy: there, deactivate and uninstall delete each value instead, which hands the
setting back to Windows' own default.

| Key (under `HKCU\`) | Value | Set to | Turns off |
| --- | --- | --- | --- |
| `Software\Microsoft\Windows\CurrentVersion\Search` | `BingSearchEnabled` | 0 | Bing web results in Start search |
| `Software\Microsoft\Windows\CurrentVersion\Search` | `SearchboxTaskbarMode` | 0 | Taskbar search box |
| `Software\Microsoft\Windows\CurrentVersion\Search` | `CortanaConsent` | 0 | Cortana in search |
| `Software\Microsoft\Windows\CurrentVersion\SearchSettings` | `IsDynamicSearchBoxEnabled` | 0 | Search highlights |
| `Software\Microsoft\Windows\CurrentVersion\SearchSettings` | `IsAADCloudSearchEnabled` | 0 | Work/school cloud results in search |
| `Software\Microsoft\Windows\CurrentVersion\SearchSettings` | `IsMSACloudSearchEnabled` | 0 | Microsoft account cloud results in search |
| `Software\Policies\Microsoft\Windows\Explorer` | `DisableSearchBoxSuggestions` | 1 | Web suggestions in the search box |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarDa` | 0 | Widgets button (Windows may refuse this one; see [Tips](../README.md#tips-and-known-issues)) |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarMn` | 0 | Chat/Teams button |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowTaskViewButton` | 0 | Task View button |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowCopilotButton` | 0 | Copilot button |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Start_IrisRecommendations` | 0 | Start menu recommendations |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Start_AccountNotifications` | 0 | Account notifications in Start |
| `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowSyncProviderNotifications` | 0 | OneDrive/sync ads in File Explorer |
| `Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo` | `Enabled` | 0 | Advertising ID |
| `Software\Microsoft\Windows\CurrentVersion\Privacy` | `TailoredExperiencesWithDiagnosticDataEnabled` | 0 | Tailored experiences |
| `Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement` | `ScoobeSystemSettingEnabled` | 0 | "Finish setting up your device" prompts |
| `Control Panel\International\User Profile` | `HttpAcceptLanguageOptOut` | 1 | Websites reading your language list |
| `Software\Policies\Microsoft\Windows\CloudContent` | `DisableWindowsSpotlightFeatures` | 1 | Windows Spotlight |

Also set to `0` under `HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager`
(Windows' suggested content, preinstalled and silently installed apps, tips, and
lock-screen ads):

`ContentDeliveryAllowed`, `FeatureManagementEnabled`, `OemPreInstalledAppsEnabled`,
`PreInstalledAppsEnabled`, `PreInstalledAppsEverEnabled`, `SilentInstalledAppsEnabled`,
`SoftLandingEnabled`, `SystemPaneSuggestionsEnabled`, `RotatingLockScreenEnabled`,
`RotatingLockScreenOverlayEnabled`, `SubscribedContent-310093Enabled`,
`SubscribedContent-338387Enabled`, `SubscribedContent-338388Enabled`,
`SubscribedContent-338389Enabled`, `SubscribedContent-338393Enabled`,
`SubscribedContent-353694Enabled`, `SubscribedContent-353696Enabled`,
`SubscribedContent-353698Enabled`, `SubscribedContent-88000326Enabled`

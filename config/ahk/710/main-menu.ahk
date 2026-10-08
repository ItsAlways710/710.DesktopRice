; Part of 710.ahk: the main menu (SUPER+Alt+Space, the tray), the messages 710sRice posts, the Start-menu commands.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

MainMenuItems() {
    global GameFlag, AwakeFlag
    return [
        {text: 'Apps',                     hint: 'SUPER+Ctrl+Space', action: (*) => ToggleFlowScoped('app ')},
        {text: 'Files',                    hint: 'SUPER+S',          action: (*) => ToggleFlowScoped('f ')},
        {text: 'Capture',                                            sub: CaptureItems},
        {text: 'Tiling',                                             sub: TilingItems},
        {text: 'Screens',                                            sub: ScreensMenuItems()},
        {text: 'Palette profiles',                                   sub: PaletteMenuItems()},
        {text: 'Keybindings',              hint: 'SUPER+K',          action: (*) => ToggleKeyOverlay()},
        {text: GameModeText(),                                       action: (*) => ToggleGameMode()},
        {text: 'Stay awake ' OnOff(AwakeFlag), hint: 'SUPER+Ctrl+W', action: (*) => ToggleStayAwake()},
        {text: 'Reload stack',             hint: 'SUPER+Shift+R',    action: (*) => ReloadStack()},
        {text: 'Doctor',                                             action: (*) => RunDoctor()},
        {text: 'System',                   hint: 'SUPER+Esc',        sub: SysMenuItems},
        {text: 'Quit 710sRice',                                      action: (*) => QuitStack()} ]
}

; Doctor: `710sRice doctor` in a new Terminal window on the cursor's monitor, left at
; a PS7 prompt afterwards so the fix it names can be typed right there. The full path
; to 710sRice.ps1 -- AHK's PATH is from sign-in, it may not know the command -- run
; inside that pwsh (-Command), so it's an ordinary shell to 710sRice ("Press Enter to
; close" is only for windows opened for the command alone). Single quotes in a clone
; path are doubled for PowerShell's '...' string.
RunDoctor() {
    global RepoRoot
    ps1 := StrReplace(RepoRoot '\710sRice.ps1', "'", "''")
    LaunchOnCursorMonitor('wt.exe -w new pwsh.exe -NoLogo -NoExit -Command "& ' "'" ps1 "'" ' doctor"'
        , 'ahk_class CASCADIA_HOSTING_WINDOW_CLASS')
}

OpenMainMenu(*) {
    if !PalClosed('menu')
        PalOpen('menu', MainMenuItems(), '710sRice')
}

; YASB's home widget "Main Menu" entry runs config\ahk\open-main-menu.ahk, which
; posts this registered message to our hidden window (YASB can only launch
; programs). Opened on a new thread so the message handler returns at once.
;
; 710.ahk runs with UI Access (AutoHotkey64_UIA.exe) so its hotkeys still land
; when an admin window has focus. The catch: Windows then drops messages from
; ordinary processes at our door (UIPI) -- the plain-AutoHotkey64 sender got
; 'Access is denied' in testing. ChangeWindowMessageFilterEx(MSGFLT_ALLOW = 1)
; opens the door for exactly the 710sRice.* messages below and nothing
; else. Harmless when running without UI Access (nothing's filtered, so there's
; nothing to allow).
AllowFromNormalProcesses(msg) {
    DllCall('ChangeWindowMessageFilterEx', 'Ptr', A_ScriptHwnd, 'UInt', msg, 'UInt', 1, 'Ptr', 0)
    return msg
}
OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.OpenMainMenu', 'UInt')), (*) => SetTimer(OpenMainMenu, -1))

; And the polite way out. A normal shell can't Stop-Process a UI Access process
; (also 'Access is denied'), so scripts\Stop-All.ps1 -- via Stop-RunningComponents
; in tools\lib\activation.ps1 -- asks us to leave instead. AHK only; Stop-All
; handles komorebi/YASB/ShareX itself, in order, before it gets here.
OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.Quit', 'UInt')), (*) => SetTimer(() => ExitApp(), -1))

; `710sRice reload` knocks here: the very same ReloadStack() as SUPER+Shift+R --
; same toasts, same double-press guard, same Reload() at the end. A reload
; already mid-flight shrugs it off; the CLI just reports that one instead (it
; reads reload-stack.log, not us).
OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.ReloadStack', 'UInt')), (*) => SetTimer(ReloadStack, -1))

; The scripts that need the bar, Flow or ShareX (back) up ask here -- `710sRice start` and
; `reload bar`, repair, update, install's Flow and ShareX steps, a theme change -- since only this
; script starts them ("The apps 710.ahk starts"). wParam says which, added up: 1 the bar, 2 Flow,
; 4 ShareX; each starts only if it isn't running. Fire-and-forget: the sender waits for the
; process itself (Start-AhkStartedApps in tools\lib\activation.ps1; the theme pipeline's Flow
; restart posts it with Send-PaletteAhkMessage, tools\lib\palette.ps1).
OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.StartApps', 'UInt')), (wParam, *) => SetTimer(() => StartApps(wParam & 7, 'asked by 710sRice'), -1))

; Install's tasks step, right after it removed the old start-up tasks: restart-after-retire.txt is
; waiting (RestartRetired, "The apps 710.ahk starts"). The sender watches the file go, then the
; apps come back as new processes (Request-RetiredAppsRestart, tools\lib\activation.ps1).
OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.RestartRetired', 'UInt')), (*) => SetTimer(RestartRetired, -1))

; The wallpaper pipeline, when wallust couldn't make a palette (PaletteFailedToast).
OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.PaletteFailed', 'UInt')), (*) => SetTimer(PaletteFailedToast, -1))

; The Start-menu commands ("710sRice Doctor", ... in Start Menu\Programs\710sRice -- Flow Launcher
; finds them; tools\components\commands.ps1 makes them, from this same list's names) each run
; config\ahk\send-command.ahk <name>, which posts '710sRice.Command.<name>' here (winarchy's
; command palette, ported 2026-10-01; its shortcuts ran its CLI, ours ask the running 710.ahk).
; Same door and UIPI opening as the messages above; each on a new thread.
RiceCommands := Map(
    'menu',              OpenMainMenu,
    'reload-stack',      ReloadStack,
    'doctor',            (*) => RunDoctor(),
    'game-mode-on',      (*) => SetGameMode(true),
    'game-mode-off',     (*) => SetGameMode(false),
    'screenshot-region', (*) => Sharex('RectangleRegion'),
    'screenshot-window', (*) => Sharex('ActiveWindow'),
    'screen-recording',  (*) => Sharex('ScreenRecorder'),
    'stop-recording',    (*) => Sharex('StopScreenRecording'),
    'text-from-screen',  (*) => Sharex('OCR'),
    'screens',           OpenScreensMenu)      ; the bar's monitor button -- no Start-menu command
for name, fn in RiceCommands
    OnMessage(AllowFromNormalProcesses(DllCall('RegisterWindowMessage', 'Str', '710sRice.Command.' name, 'UInt')), RiceCommandHandler(fn))
RiceCommandHandler(fn) => (*) => SetTimer(() => fn(), -1)

; Builds a native Menu() tree from the shared {text, action}/{text, sub}
; structure -- recursive so Capture/Tiling/System (all one level deep today)
; and any deeper nesting later both just work.
BuildNativeMenu(menuObj, items) {
    for item in items {
        if item.HasOwnProp('sub') {
            childMenu := Menu()
            BuildNativeMenu(childMenu, item.sub)
            menuObj.Add(NativeMenuName(item), childMenu)
        } else {
            menuObj.Add(NativeMenuName(item), item.action)
        }
    }
}

; A tab in a native menu item's name puts what follows in Windows' own
; right-aligned accelerator column -- so the tray shows the same key hints as
; the palette.
NativeMenuName(item) => item.text (item.HasOwnProp('hint') ? '`t' item.hint : '')

SetupTray() {
    ico := RepoRoot "\assets\logo\710rice.ico"
    if FileExist(ico)
        try TraySetIcon(ico)   ; 710 in Chiefs red on white, in a gold border; AutoHotkey's own icon if the file is missing
    A_IconTip := '710sRice'

    RebuildTrayMenu()
    ; Rebuilt on every right-click (as the button goes down; Windows shows it on the
    ; way up), so it lists the palette profiles there are now and Game mode's current
    ; state -- like SUPER+Alt+Space, which builds its list on every open.
    OnMessage(0x404, (wParam, lParam, *) => ((lParam & 0xFFFF) = 0x204 ? RebuildTrayMenu() : ''))   ; AHK_NOTIFYICON, WM_RBUTTONDOWN
}

RebuildTrayMenu() {
    tray := A_TrayMenu
    tray.Delete()               ; drop AHK's default Pause/Suspend/Reload/Edit menu (and the last build)
    items := MainMenuItems()
    BuildNativeMenu(tray, items)
    try tray.Default := NativeMenuName(items[1])   ; Apps -- try: a name mismatch must never stop AHK loading
    tray.ClickCount := 1        ; single left-click runs Default, matching winarchy
}
SetupTray()

#!Space::OpenMainMenu()             ; main menu (Apps/Capture/Tiling/Game mode/...)

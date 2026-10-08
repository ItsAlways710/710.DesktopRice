; Part of 710.ahk: App launchers -- the browser, Explorer, web apps, Obsidian, Claude.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; ============================================================================
; App launchers
; ============================================================================
; Reads the real default-browser registry association rather than assuming
; one -- ported from winarchy's DefaultBrowser(). Falls back to Edge (always
; present on Windows 11) if the registry read fails for any reason.
DefaultBrowser() {
    try {
        progId := RegRead('HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice', 'ProgId')
        cmd := RegRead('HKCR\' progId '\shell\open\command')
        exe := RegExReplace(cmd, '^"([^"]+)".*$', '$1')
        if FileExist(exe)
            return exe
    }
    return 'msedge.exe'
}

; Chromeless app-mode window (--app=, Chromium-based browsers only -- Firefox
; would just open a normal tab instead). Ported from winarchy's WebApp().
WebApp(url) {
    Run('"' DefaultBrowser() '" --app=' url)
}

#b::Run(DefaultBrowser())                         ; default browser
#e::Run('explorer.exe')                           ; file explorer
#y::WebApp('https://youtube.com')                 ; YouTube
#m::WebApp('https://music.youtube.com')           ; YouTube Music (instead of Windows' minimize-all)
#o::LaunchObsidian()                              ; Obsidian
#^d::Run('ms-settings:display')                   ; Windows display settings (instead of a new virtual desktop)

; Obsidian (winarchy's SUPER+O, ported 2026-10-01). Its installer is per-user: winarchy looked in
; %LOCALAPPDATA%\Obsidian, today's installer uses %LOCALAPPDATA%\Programs\Obsidian. Neither there
; (a portable or moved copy): the obsidian:// link it registers, if there is one -- for you (what
; its installer writes) or for the machine. None of those: a toast. Obsidian keeps one window --
; a second start just brings it forward.
LaunchObsidian() {
    for dir in [EnvGet('LOCALAPPDATA') '\Obsidian', EnvGet('LOCALAPPDATA') '\Programs\Obsidian']
        if FileExist(dir '\Obsidian.exe') {
            Run('"' dir '\Obsidian.exe"')
            return
        }
    for key in ['HKCU\Software\Classes\obsidian\shell\open\command', 'HKLM\Software\Classes\obsidian\shell\open\command']
        try {
            if (RegRead(key) != '') {
                Run('obsidian://')
                return
            }
        }
    TrayTip('Obsidian is not installed', '710sRice')
}

; Best-effort path -- %LOCALAPPDATA%\Claude is walled off from the device
; bridge that built this (Claude's own app-data folders are protected), so
; this couldn't be directly verified the way everything else in this file
; is. Standard install location for this kind of app on Windows; if it's
; wrong the TrayTip below will say so rather than silently doing nothing.
LaunchClaudeDesktop() {
    ; The Claude desktop app is a packaged (MSIX) app: its exe sits in a
    ; versioned folder under Program Files\WindowsApps that changes with every
    ; update, so it's launched by its app ID, the way the Start menu does it.
    ; (The old guess, %LOCALAPPDATA%\Claude\Claude.exe, is only the app's data
    ; folder -- plan item 26.) App ID from
    ; `Get-StartApps | Where-Object Name -like '*Claude*'` (2026-09-24). The
    ; package's own folder under %LOCALAPPDATA%\Packages exists once it's
    ; installed, so that's the "is it installed" check.
    if !DirExist(EnvGet('LOCALAPPDATA') '\Packages\Claude_pzs8sxrjxfjjc') {
        TrayTip('The Claude desktop app is not installed', '710sRice')
        return
    }
    try Run('shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude')
    catch as e
        TrayTip("Couldn't start the Claude desktop app: " e.Message, '710sRice')
}

#+a::LaunchClaudeDesktop()                        ; Claude Desktop (SUPER+Shift+A)

; Part of 710.ahk: komorebi's keys -- windows, focus, move, stacks, resize, workspaces, monitors.
; config\ahk\710.ahk #Includes it in place -- not a script to run on its own.
#Requires AutoHotkey v2.0

; --- Windows -----------------------------------------------------------
#q::CloseWindow()                                ; close window
                                                  ; (#w, then #x, now #q since 2026-10-03: Win+X is Windows'
                                                  ; own power-user menu and earns its key back; Win+Q's
                                                  ; search is redundant next to Flow and Everything)
#w::Send('^!w')                                  ; open wallpaper gallery
                                                  ; (re-sends YASB's own native ctrl+alt+w hotkey,
                                                  ; toggle_gallery, rather than duplicating it; needs
                                                  ; a live check that it fires regardless of focus)
#f::Komorebic('toggle-monocle')                  ; monocle (logical fullscreen)
#+f::Komorebic('toggle-maximize')                ; real maximize
#t::Komorebic('toggle-float')                    ; float/tile
#p::Komorebic('toggle-pause')                    ; pause tiling
#^t::Komorebic('retile')                         ; force retile (SUPER+R is left to Windows: Win+R = Run)
#+r::ReloadStack()                               ; reload: re-apply config + rules, restart only what changed
#^r::RestartStack()                              ; restart the whole stack (stop + start)
#^c::RedrawApp()                                 ; redraw this app (fixes Chrome's / Claude's extra title bar)
#+Enter::Komorebic('promote')                    ; promote to largest tile
#+l::Komorebic('cycle-layout next')              ; cycle to next layout
#!l::ToggleScrolling()                           ; toggle scrolling layout - 2 cols
#Tab::Komorebic('focus-last-workspace')          ; back to the previous workspace
#+Tab::Komorebic('move-to-last-workspace')       ; send window to previous workspace
#^Enter::Komorebic('promote-focus')              ; focus top of the tree
#+h::Komorebic('flip-layout horizontal')         ; mirror the layout left/right
#+j::Komorebic('flip-layout vertical')           ; mirror the layout up/down
#+z::Komorebic('toggle-tiling')                  ; toggle tiling this workspace
#!Home::Komorebic('quick-save-resize')           ; save current tile sizes
#Home::Komorebic('quick-load-resize')            ; restore them
#+d::Komorebic('toggle-transparency')            ; dim unfocused windows
#^m::Komorebic('minimize')                       ; minimize the focused window
#^f::Komorebic('toggle-workspace-layer')         ; toggle tiling/floating layer
#^l::Komorebic('toggle-lock')                    ; lock container (pin it)

; --- Focus ---------------------------------------------------------------
#Left::Komorebic('focus left')                   ; move focus
#Right::Komorebic('focus right')
#Up::Komorebic('focus up')
#Down::Komorebic('focus down')

; --- Move window -----------------------------------------------------------
#+Left::Komorebic('move left')                   ; move window
#+Right::Komorebic('move right')
#+Up::Komorebic('move up')
#+Down::Komorebic('move down')

; --- Stacks ---
; komorebi draws these as tabs in the stackbar
#!Left::Komorebic('stack left')                  ; stack with neighbor
#!Right::Komorebic('stack right')
#!Up::Komorebic('stack up')
#!Down::Komorebic('stack down')
#!u::Komorebic('unstack')                        ; unstack this window
#^s::Komorebic('stack-all')                      ; stack the whole workspace
#^u::Komorebic('unstack-all')                    ; unstack the whole container
#!,::Komorebic('cycle-stack previous')           ; previous tab in the stack
#!.::Komorebic('cycle-stack next')               ; next tab in the stack

; --- Resize ------------------------------------------------------------------
#=::Komorebic('resize-axis horizontal increase') ; width +
#-::Komorebic('resize-axis horizontal decrease') ; width -
#+=::Komorebic('resize-axis vertical increase')  ; height +
#+-::Komorebic('resize-axis vertical decrease')  ; height -

; --- Workspaces --------------------------------------------------------------
; 1-9 (komorebi, no native virtual desktops)
#1::Komorebic('focus-workspace 0')               ; go to workspace N
#2::Komorebic('focus-workspace 1')
#3::Komorebic('focus-workspace 2')
#4::Komorebic('focus-workspace 3')
#5::Komorebic('focus-workspace 4')
#6::Komorebic('focus-workspace 5')
#7::Komorebic('focus-workspace 6')
#8::Komorebic('focus-workspace 7')
#9::Komorebic('focus-workspace 8')

#+1::Komorebic('move-to-workspace 0')            ; move window to workspace N
#+2::Komorebic('move-to-workspace 1')
#+3::Komorebic('move-to-workspace 2')
#+4::Komorebic('move-to-workspace 3')
#+5::Komorebic('move-to-workspace 4')
#+6::Komorebic('move-to-workspace 5')
#+7::Komorebic('move-to-workspace 6')
#+8::Komorebic('move-to-workspace 7')
#+9::Komorebic('move-to-workspace 8')

#^1::Komorebic('send-to-workspace 0')            ; send window, focus stays
#^2::Komorebic('send-to-workspace 1')
#^3::Komorebic('send-to-workspace 2')
#^4::Komorebic('send-to-workspace 3')
#^5::Komorebic('send-to-workspace 4')
#^6::Komorebic('send-to-workspace 5')
#^7::Komorebic('send-to-workspace 6')
#^8::Komorebic('send-to-workspace 7')
#^9::Komorebic('send-to-workspace 8')

; --- Monitors ------------------------------------------------------------------
#,::Komorebic('cycle-monitor previous')          ; focus previous monitor
#.::Komorebic('cycle-monitor next')              ; focus next monitor
#+,::Komorebic('cycle-move-to-monitor previous') ; move to previous monitor
#+.::Komorebic('cycle-move-to-monitor next')     ; move to next monitor
#^,::Komorebic('cycle-send-to-monitor previous') ; send to previous monitor
#^.::Komorebic('cycle-send-to-monitor next')     ; send to next monitor
#!+,::Komorebic('cycle-move-workspace-to-monitor previous')  ; move workspace to prev monitor
#!+.::Komorebic('cycle-move-workspace-to-monitor next')      ; move workspace to next monitor

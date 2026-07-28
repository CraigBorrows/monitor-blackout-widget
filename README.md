# Monitor Blackout — KDE Plasma 6 widget

A panel widget for KDE Plasma 6 (Wayland) that blacks out the monitors you're
not using — built for gaming on one screen of a three-monitor setup without
light spilling from the others.

- **Popup:** your monitors drawn in their real arrangement. Click one to black
  it out, click again to bring it back.
- **Middle-click the panel icon:** black out everything except the primary,
  middle-click again to restore. No popup needed.
- **Right-click:** the same two actions as menu entries.
- **Click a blacked-out screen** to restore it — the escape hatch that still
  works when the panel itself is behind an overlay.

## How it blacks a screen

Two things at once, because neither is enough alone:

1. A **pure black X11 window** covering that output, so the pixels are black.
2. **DDC/CI brightness to 0** via `kscreen-doctor`, so the backlight stops
   glowing through the black.

Measured on this hardware: brightness 0 alone is *dark but not black* — the
backlight is still lit. KWin's separate compositor-side `dimming` control at 0
is likewise dark, not black. A black window alone leaves the backlight on.
Together they get as close to "off" as a lit LCD gets.

**Outputs stay enabled the whole time.** That is the point: `kscreen-doctor
output.X.disable` genuinely powers a monitor down, but KWin then relocates every
window on it to a surviving screen and they do not come back. DPMS has the same
appeal and the same problem — plus it wakes on input, which is useless while
gaming. Keeping the output enabled and covering it means nothing moves.

## Why X11 on a Wayland desktop

A Wayland client cannot choose which output its surface appears on. Both
documented routes were tried on this setup and **both put every overlay on
screen 0**, silently:

- a fullscreen `Window` with `screen` set — KWin places fullscreen toplevels on
  the active output and ignores the requested one;
- a **layer-shell** surface with `LayerShell.Window.screen` +
  `ScreenFromQWindow` — no effect inside plasmashell (the shell integration is
  fixed long before a widget loads), and no effect in a separate process even
  with `QT_WAYLAND_SHELL_INTEGRATION=layer-shell` forced.

An **X11 override-redirect window** placed through XWayland is positioned at
exactly the coordinates it asks for, and XWayland's coordinate space matches
the Wayland output layout — so the monitor is addressed by *where it is* rather
than by a name the compositor is free to disregard. `override_redirect` also
means KWin does not manage the window: no placement policy, no focus stealing,
no taskbar entry.

`contents/code/overlay-x11.py` talks to libX11 through `ctypes`, so there is no
binding to install. One process per blacked-out screen, killed by its label to
restore.

## Layout

```
package/
  metadata.json                   # id com.cbo.monitorblackout
  contents/
    ui/main.qml                   # map, click handling, brightness control
    code/overlay-x11.py           # one black X11 window per blacked-out output
    code/outputs.py               # kscreen-doctor -j -> brightness + priority,
                                  # plus which overlay processes are alive
    config/main.xml               # persists brightness for crash recovery
install.sh                        # dev install: symlink + cache clear + restart
```

## Install

```sh
./install.sh
```

Symlinks `package/` to `~/.local/share/plasma/plasmoids/com.cbo.monitorblackout`,
so editing files here edits the live widget. Add it via right-click panel →
*Add Widgets* → "Monitor Blackout".

## Recovering a stuck screen

Overlays are detached processes, so they outlive plasmashell — as does
brightness 0. The widget therefore starts from a clean slate: on load it kills
any stray overlays and restores the brightness it recorded in its config. To
fix one by hand:

```sh
pkill -f overlay-x11.py
kscreen-doctor output.DP-1.brightness.100
```

Clicking a blacked-out screen also dismisses its overlay; the widget polls
while anything is blacked out, notices the process is gone, and puts that
screen's brightness back.

## Gotcha: the QML cache

Plasma serves a **compiled** copy of the QML from
`~/.cache/plasmashell/qmlcache/`. A plain plasmashell restart replays the cached
build, so source edits won't appear until that cache is cleared. `install.sh`
does it for you.

# CLAUDE.md — monitor-blackout-widget

KDE Plasma 6 (Plasma 6.6, Qt6/KF6) panel widget that blacks out the monitors
you aren't using, for gaming on one screen of a three-monitor setup without
light spilling from the others. Built for Craig's Fedora 43 / KDE **Wayland**
workstation. Sibling of `cpu-widget`, `memory-widget` and
`claude-usage-widget`; same package layout and install flow, but this one
*acts on* the system rather than just reporting on it, which is where all the
interesting failure modes live.

`README.md` explains what the widget does and why X11 is used on Wayland —
read it first. This file is about working on the code.

## Working on this

- Source of truth is this project. `package/` is **symlinked** into
  `~/.local/share/plasma/plasmoids/com.cbo.monitorblackout`. Both helpers live
  inside the package under `contents/code/` and are resolved at runtime via
  `Qt.resolvedUrl`, so there's no separate `~/.local/bin` install.
  `./install.sh` recreates the symlink, clears the QML cache and restarts
  plasmashell.
- **Always clear `~/.cache/plasmashell/qmlcache/` after editing `main.qml`** —
  Plasma runs the *compiled* cache, so a plain restart shows no change. This is
  the single biggest footgun across all four widgets. `install.sh` handles it.
- There is **no `build.sh`** here (the siblings have one), though `.gitignore`
  already expects its output. To produce a distributable:
  `kpackagetool6 --type Plasma/Applet --package package -o dist/monitor-blackout.plasmoid`
- Test the helpers directly, which is much faster than reloading the widget:
  - `python3 package/contents/code/outputs.py | python3 -m json.tool`
  - `python3 package/contents/code/overlay-x11.py blackout-test 0 0 400 300`
    then `pkill -f overlay-x11.py` — click the black square and it exits on its
    own, which is the escape hatch working.

### plasmoidviewer is NOT side-effect-free here

For the three reporting widgets, `plasmoidviewer -a com.cbo.<id>` is a safe
offscreen check. **It is not safe for this one.** `Component.onCompleted` calls
`recover()`, which unconditionally runs
`pkill -9 -f "overlay-x11[.]py blackout-"` and then pushes `kscreen-doctor`
brightness values from saved config. Launching plasmoidviewer while screens are
actually blacked out will kill the live overlays and move real backlights.
Restore everything first, or accept that it will.

## The two-part blackout

Neither half is sufficient alone, which is the whole design:

1. A **black X11 override-redirect window** over the output (pixels black).
2. **DDC/CI brightness to 0** via `kscreen-doctor` (backlight stops glowing
   through the black). Optional — `dimBacklight` in config.

**Outputs stay enabled throughout.** `kscreen-doctor output.X.disable` and DPMS
both genuinely power the monitor down, but KWin then relocates every window off
that screen and they do not come back. Covering an enabled output means nothing
moves. Don't "simplify" this into disabling outputs.

## State model

`blanked` is a map of `output name -> brightness to restore to`; its *presence*
is what "blacked out" means, and `blankedCount` drives the badge, the tooltip
and the poll timer. Geometry comes from `Qt.application.screens`; brightness
and priority come from `kscreen-doctor -j` via `outputs.py`. `mergeOutputs()`
joins them **by output name** — that join is the contract between the two
sources.

Three mechanisms keep reality and state in agreement:

- **`reconcile(live)`** — `outputs.py` reports which overlay processes are
  actually alive. Anything in `blanked` without a live overlay gets restored.
  This is how a user click on an overlay is noticed, since the overlay exits
  silently.
- **The 2 s timer**, running only while `blankedCount > 0`. It exists to drive
  `reconcile`, and it doubles as the **error path for a failed overlay launch**:
  `openOverlay()` is fire-and-forget through the DataSource and always returns
  `true`, so a launch failure is undetectable at call time — but the next
  reconcile sees no live overlay and restores that screen within ~2 s. The
  `if (!openOverlay(o)) return` guard is therefore vestigial; leave the self-heal
  path intact if you touch it.
- **`persist()` / `recover()`** — overlays are detached with `setsid` and so
  outlive plasmashell, and brightness 0 outlives it too. A crash could otherwise
  strand a monitor dark with no widget behind it. `blanked` is written to
  `savedBrightness` on every change, and `recover()` starts from a known-clean
  slate on load.

## Gotchas, all of which bit once

- **The `pkill` pattern is load-bearing in two ways.** `overlay-x11[.]py` — the
  bracket stops the shell running `pkill` from matching the pattern it is
  searching for, or it races to kill itself. And the **trailing space** after
  the label anchors the name, or `blackout-DP-1 ` would also match a
  hypothetical `DP-11`. `recover()` deliberately omits the trailing space to
  sweep *all* overlays.
- **Setter commands share the DataSource with the reader.** `onNewData` bails
  out unless `sourceName` contains `outputs.py`, so `kscreen-doctor` and
  overlay launches are fire-and-forget. A setter that starts needing its output
  parsed has to be distinguished there first.
- **`seq` wraps at 8 — never make it unbounded.** Plasma5Support keeps source
  names in a `QQmlPropertyMap` backed by an append-only `QQmlOpenMetaObject`,
  and rebuilds the whole metaobject on every connect *and* disconnect (removing
  a source *adds* a property: `removeSource` → `clear()` → `setValue` →
  `createProperty`). Unbounded, each run costs O(runs so far). This widget only
  runs on demand so it never got as bad as the 3 s sibling pollers — those
  reached ~28k names each over a day and left plasmashell's main thread pinned
  at 100% CPU with 1.3 GB RSS — but the growth is the same shape.
- **`brightness: null` means the panel has no DDC/CI control.** `outputs.py`
  emits null rather than a number, and `blank()` skips the `kscreen-doctor`
  round-trip entirely — the call would just stall. Guard any new brightness
  code the same way.
- **kscreen-doctor reports brightness as 0..1 but accepts 0..100.**
  `outputs.py` converts on the way out so the QML only ever deals in percent.
- **Priority 1 is the primary screen** (`isPrimary`), defaulting to 99 when
  kscreen doesn't report one. There is no `primary` boolean to read.
- **A screen already at brightness 0 restores to 100**, not to 0 — `saved`
  falls back to 100 when the reading is null or zero. Restoring a monitor to
  the dark it was already in would look exactly like the widget being broken.
- **`restore()` doesn't check `dimBacklight`,** deliberately: if the setting was
  turned off mid-blackout, the screen still needs whatever was dimmed put back.
  When nothing was dimmed this is a no-op that costs one DDC round-trip.
- **XWayland must be running** and `libX11` present — `overlay-x11.py` finds it
  through `ctypes.util.find_library("X11")` and exits with `cannot open
  display` otherwise. A pure-Wayland session with XWayland disabled has no
  overlay at all, only dimming.

## Conventions

- Panel: a single `video-display` icon with a count badge when anything is
  blacked out. Middle-click is the one-handed path — blank all but primary,
  middle-click again to restore — matching the middle-click-does-the-useful-
  thing convention in the sibling widgets.
- The popup draws the monitors to **real relative geometry** under a uniform
  scale, so the map matches the physical arrangement; click a rectangle to
  toggle it.
- Config lives in `config/main.xml` and binds through the `cfg_` prefix
  (`cfg_dimBacklight` ↔ `dimBacklight`). `savedBrightness` is internal state,
  not a user setting, and has no UI.

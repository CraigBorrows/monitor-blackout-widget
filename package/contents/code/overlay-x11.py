#!/usr/bin/env python3
"""Black overlay pinned to an absolute rectangle, via XWayland.

Usage: overlay-x11.py <label> <x> <y> <w> <h>

Why X11 on a Wayland desktop: a Wayland client cannot choose which output its
surface goes to. Both documented routes were tried and both put every surface
on screen 0 regardless — a fullscreen xdg_toplevel with Window.screen set, and
a layer-shell surface with LayerShell.Window.screen + ScreenFromQWindow, the
latter even with QT_WAYLAND_SHELL_INTEGRATION=layer-shell forced in its own
process. An X11 override-redirect window, by contrast, is placed at the exact
coordinates it asks for, and XWayland's coordinate space matches the Wayland
output layout — so addressing a monitor by its geometry just works.

override_redirect also means KWin does not manage the window: no placement
policy, no focus stealing, no taskbar entry. It stays until this process is
killed, which is how the widget takes it down.

The <label> argument is not used for anything except making the process line
greppable, so the widget can kill exactly the overlay it wants.
"""
import ctypes
import ctypes.util
import signal
import sys
import time

CW_BACK_PIXEL = 1 << 1
CW_OVERRIDE_REDIRECT = 1 << 9
CW_EVENT_MASK = 1 << 11
BUTTON_PRESS_MASK = 1 << 2
BUTTON_PRESS = 4
INPUT_OUTPUT = 1
COPY_FROM_PARENT = 0


class XEvent(ctypes.Union):
    _fields_ = [("type", ctypes.c_int), ("pad", ctypes.c_long * 24)]


class XSetWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("background_pixmap", ctypes.c_ulong),
        ("background_pixel", ctypes.c_ulong),
        ("border_pixmap", ctypes.c_ulong),
        ("border_pixel", ctypes.c_ulong),
        ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int),
        ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int),
        ("event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int),
        ("colormap", ctypes.c_ulong),
        ("cursor", ctypes.c_ulong),
    ]


def main():
    if len(sys.argv) != 6:
        print("usage: overlay-x11.py <label> <x> <y> <w> <h>", file=sys.stderr)
        return 2
    _label, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:6])

    path = ctypes.util.find_library("X11")
    if not path:
        print("libX11 not found", file=sys.stderr)
        return 1
    x11 = ctypes.CDLL(path)

    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XRootWindow.restype = ctypes.c_ulong
    x11.XRootWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XDefaultScreen.restype = ctypes.c_int
    x11.XDefaultScreen.argtypes = [ctypes.c_void_p]
    x11.XCreateWindow.restype = ctypes.c_ulong
    x11.XCreateWindow.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
        ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_int,
        ctypes.c_uint, ctypes.c_void_p, ctypes.c_ulong,
        ctypes.POINTER(XSetWindowAttributes),
    ]
    x11.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XFlush.argtypes = [ctypes.c_void_p]

    dpy = x11.XOpenDisplay(None)
    if not dpy:
        print("cannot open display", file=sys.stderr)
        return 1

    screen = x11.XDefaultScreen(dpy)
    root = x11.XRootWindow(dpy, screen)

    x11.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.POINTER(XEvent)]

    attrs = XSetWindowAttributes()
    attrs.background_pixel = 0x000000
    attrs.override_redirect = 1
    attrs.event_mask = BUTTON_PRESS_MASK

    win = x11.XCreateWindow(
        dpy, root, x, y, w, h, 0, COPY_FROM_PARENT, INPUT_OUTPUT, None,
        CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK,
        ctypes.byref(attrs))
    x11.XMapRaised(dpy, win)
    x11.XFlush(dpy)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    # Clicking the black screen exits, which is the escape hatch when the panel
    # itself is behind an overlay. The widget notices the process is gone and
    # puts the brightness back.
    ev = XEvent()
    while True:
        x11.XNextEvent(dpy, ctypes.byref(ev))
        if ev.type == BUTTON_PRESS:
            return 0


if __name__ == "__main__":
    raise SystemExit(main())

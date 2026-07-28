#!/usr/bin/env python3
"""List the connected outputs with their current backlight brightness.

Geometry comes from Qt inside the widget; this only supplies what Qt cannot
see — the DDC/CI brightness level and KScreen's output priority (priority 1
is the primary screen). Brightness is reported by kscreen-doctor as 0..1 and
emitted here as a 0..100 percentage, matching what the setter accepts."""
import glob
import json
import os
import subprocess


def emit(obj):
    print(json.dumps(obj))
    raise SystemExit(0)


try:
    raw = subprocess.run(["kscreen-doctor", "-j"], capture_output=True,
                         text=True, timeout=10)
except FileNotFoundError:
    emit({"error": "no-kscreen-doctor"})
except Exception:
    emit({"error": "exec"})

if raw.returncode != 0:
    emit({"error": "kscreen-%d" % raw.returncode})

try:
    data = json.loads(raw.stdout)
except Exception:
    emit({"error": "parse"})

outputs = []
for o in data.get("outputs", []):
    if not o.get("connected"):
        continue
    b = o.get("brightness")
    outputs.append({
        "name": o.get("name"),
        "enabled": bool(o.get("enabled")),
        "priority": o.get("priority"),
        # null brightness => the panel has no DDC/CI control; the widget then
        # relies on the overlay alone rather than pretending it can dim.
        "brightness": round(b * 100) if isinstance(b, (int, float)) else None,
    })

def live_overlays():
    """Names of outputs that currently have an overlay process alive.

    The widget reconciles against this: an overlay the user dismissed by
    clicking it is gone from here, which is the widget's cue to put that
    screen's brightness back."""
    found = []
    for cmdline in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(cmdline, "rb") as f:
                args = f.read().split(b"\0")
        except OSError:
            continue
        if not any(a.endswith(b"overlay-x11.py") for a in args):
            continue
        for a in args:
            if a.startswith(b"blackout-"):
                found.append(a[len(b"blackout-"):].decode("utf-8", "replace"))
    return found


emit({"ok": True, "outputs": outputs, "overlays": live_overlays()})

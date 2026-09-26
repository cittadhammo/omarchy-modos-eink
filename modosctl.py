#!/usr/bin/env python3
"""Small JSON CLI for the Modos Glider API.

``status`` reports connection state plus, on firmware new enough to support
it, the device's actual lightness/contrast and refresh mode read back over
USB HID. On older firmware it falls back to the last locally requested mode,
stored in ~/.local/state/modos-eink/state.json, and reports that as
``modeSource: local-state`` rather than pretending it is hardware read-back.

``redraw`` forces the device to do a hard full-screen refresh (black to
white) to clear accumulated ghosting, matching the Dev Kit's third physical
button.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from typing import Any


VID = "1209"
PID = "ae86"

# Technical mode names as spelled by glider-api's Mode enum. The device's own
# on-screen menu instead shows four behaviour presets (Browsing/Typing/
# Reading/Watching). No authoritative enum<->preset table exists anywhere in
# Modos' SDK/docs, so each API mode carries a human label derived from the
# published descriptions of those presets, while the technical name stays
# visible as a secondary line in the UI.
MODE_NAMES = (
    "FastMonoNoDither",
    "FastMonoBayer",
    "FastMonoBlueNoise",
    "FastGrey",
    "AutoNoDither",
    "AutoErrorDiffusion",
)

MODE_LABELS = {
    # Device preset: "Browsing ... sharpest text ... most stable image
    # (binary mode)" -> the API's fastest no-dither 1-bit mode.
    "FastMonoNoDither": "Browsing",
    # Watching prioritises speed for motion; the API pairs fast 1-bit with
    # ordered dithering for games/fast-moving content.
    "FastMonoBayer": "Watching",
    "FastMonoBlueNoise": "Watching",
    # Device preset: "Typing ... responsive text editing, mixing sharp text
    # with 4-level grayscale" -> the API's 4-level greyscale mode.
    "FastGrey": "Typing",
    # Device preset: "Reading ... flips pages quickly, high fidelity when
    # settled" -> the API's hybrid binary/greyscale modes.
    "AutoNoDither": "Reading",
    "AutoErrorDiffusion": "Reading",
}

MODE_DESCRIPTIONS = {
    "FastMonoNoDither": "Binary mode: sharpest text, most stable image.",
    "FastMonoBayer": "Fast 1-bit with ordered (Bayer) dithering; motion and games.",
    "FastMonoBlueNoise": "Fast 1-bit with blue-noise dithering; smoother gradients.",
    "FastGrey": "4-level greyscale tuned for responsive typing.",
    "AutoNoDither": "Fast binary while changing, greyscale once settled.",
    "AutoErrorDiffusion": "Fast binary, then Floyd-Steinberg-style greyscale when settled.",
}

# Tone ranges as enforced by the controller firmware (same steps as the
# on-screen menu).
LIGHTNESS_MIN, LIGHTNESS_MAX = -3, 3
CONTRAST_MIN, CONTRAST_MAX = -1, 6

# Auto Clear settings as enforced by the controller firmware (mirrors the
# OSD's Auto Clear submenu). Index = the value sent over HID.
AC_MODES = ("Off", "Adaptive", "Fixed")
AC_INTERVALS = ("1 min", "5 min", "15 min")
AC_THRESHOLDS = ("Sometimes", "Occasionally", "Often")

# Firmware mode ordinals (from caster.h's update_mode_t) to glider-api names.
_MODE_NAMES_BY_ORDINAL = {
    0: "ManualLUTNoDither",
    1: "ManualLUTErrorDiffusion",
    2: "FastMonoNoDither",
    3: "FastMonoBayer",
    4: "FastMonoBlueNoise",
    5: "FastGrey",
    6: "AutoNoDither",
    7: "AutoErrorDiffusion",
}


def state_path() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return base / "modos-eink" / "state.json"


def find_hidraw() -> list[Path]:
    """Return hidraw nodes whose USB ancestor has the Glider VID/PID."""
    matches: list[Path] = []
    for link in sorted(Path("/sys/class/hidraw").glob("hidraw*")):
        current = (link / "device").resolve()
        for parent in (current, *current.parents):
            vendor = parent / "idVendor"
            product = parent / "idProduct"
            try:
                if vendor.read_text().strip().lower() == VID and product.read_text().strip().lower() == PID:
                    matches.append(Path("/dev") / link.name)
                    break
            except OSError:
                continue
    return matches


def local_state() -> dict[str, Any]:
    try:
        data = json.loads(state_path().read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_state(mode: str) -> None:
    destination = state_path()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(json.dumps({"mode": mode}) + "\n")
    temporary.replace(destination)


def emit(payload: dict[str, Any]) -> None:
    payload.setdefault("modeLabels", MODE_LABELS)
    payload.setdefault("modeDescriptions", MODE_DESCRIPTIONS)
    payload.setdefault("acModes", AC_MODES)
    payload.setdefault("acIntervals", AC_INTERVALS)
    payload.setdefault("acThresholds", AC_THRESHOLDS)
    print(json.dumps(payload, separators=(",", ":")))


def unavailable(reason: str, nodes: list[Path]) -> int:
    emit({
        "ok": False,
        "connected": bool(nodes),
        "hidraw": [str(node) for node in nodes],
        "error": reason,
        "modes": list(MODE_NAMES),
    })
    print("modosctl: " + reason, file=sys.stderr)
    return 1


def require_device() -> tuple[int, list[Path]]:
    nodes = find_hidraw()
    if not nodes:
        return unavailable(
            "Modos Glider (1209:ae86) was not found; check the USB-C cable and DP/USB connection.",
            nodes,
        ), nodes
    inaccessible = [node for node in nodes if not os.access(node, os.R_OK | os.W_OK)]
    if inaccessible:
        return unavailable(
            "permission denied for " + ", ".join(map(str, inaccessible))
            + "; install udev/69-modos-glider.rules, reload rules, then reconnect the display.",
            nodes,
        ), nodes
    return 0, nodes


def api() -> tuple[Any, Any, Any, Any, Any]:
    try:
        from glider_api import AutoClear, Display, DisplayConfig, Mode, Tone
        return Display, DisplayConfig, Mode, Tone, AutoClear
    except ImportError as exc:
        raise RuntimeError(
            "glider_api is not installed for " + sys.executable
            + "; install it with: " + sys.executable
            + " -m pip install ~/github/glider-api"
            + " (after `git -C ~/github/glider-api checkout "
            + "dff53d56d58e26256d49959df7676821c5d2c5bc`)"
        ) from exc


def _indexed(values: tuple[str, ...], index: int) -> str:
    """Label lookup that survives a firmware reporting an unknown index."""
    return values[index] if 0 <= index < len(values) else str(index)


def status() -> int:
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, _Mode, _Tone, _AutoClear = api()
        config = DisplayConfig.glider_standard()
        # Opening verifies hidapi can actually claim the matching USB device.
        display = Display.new_with_config(config)
    except Exception as exc:
        return unavailable("could not open the Modos HID device: " + str(exc), nodes)
    saved = local_state()
    payload: dict[str, Any] = {
        "ok": True,
        "connected": True,
        "hidraw": [str(node) for node in nodes],
        "modes": list(MODE_NAMES),
        "lightnessRange": [LIGHTNESS_MIN, LIGHTNESS_MAX],
        "contrastRange": [CONTRAST_MIN, CONTRAST_MAX],
    }
    tone = read_tone(display)
    if tone is not None:
        payload["tone"] = {"lightness": tone[0], "contrast": tone[1], "source": "device"}
        mode = read_mode(display)
        if mode is not None:
            payload["mode"] = mode
            payload["modeSource"] = "device"
        else:
            payload["mode"] = saved.get("mode", "unknown")
            payload["modeSource"] = "local-state (device did not report mode)"
    else:
        payload["tone"] = None
        payload["mode"] = saved.get("mode", "unknown")
        payload["modeSource"] = "local-state (device firmware does not support read-back)"
    ac = read_autoclear(display)
    if ac is not None:
        ac_mode, ac_interval, ac_threshold = ac
        payload["autoclear"] = {
            "mode": _indexed(AC_MODES, ac_mode),
            "interval": _indexed(AC_INTERVALS, ac_interval),
            "threshold": _indexed(AC_THRESHOLDS, ac_threshold),
            "source": "device",
        }
        payload["autoclearAvailable"] = True
    else:
        payload["autoclear"] = None
        payload["autoclearAvailable"] = False
    emit(payload)
    return 0


def read_tone(display: Any) -> tuple[int, int] | None:
    """Return (lightness, contrast) read from the device, or None."""
    try:
        tone = display.get_tone()
        return int(tone.lightness), int(tone.contrast)
    except Exception:
        return None


def read_mode(display: Any) -> str | None:
    """Return the device's current mode name, or None."""
    try:
        return _MODE_NAMES_BY_ORDINAL.get(int(display.get_mode()))
    except Exception:
        return None


def read_autoclear(display: Any) -> tuple[int, int, int] | None:
    """Return (mode, interval, threshold) read from the device, or None."""
    try:
        ac = display.get_autoclear()
        return int(ac.mode), int(ac.interval), int(ac.threshold)
    except Exception:
        return None


def set_mode(name: str) -> int:
    if name not in MODE_NAMES:
        return unavailable("unknown mode '" + name + "'", find_hidraw())
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, Mode, _Tone, _AutoClear = api()
        config = DisplayConfig.glider_standard()
        display = Display.new_with_config(config)
        display.set_mode(getattr(Mode, name), config.full_screen())
        write_state(name)
    except Exception as exc:
        return unavailable("could not set " + name + ": " + str(exc), nodes)
    emit({"ok": True, "connected": True, "mode": name, "modes": list(MODE_NAMES)})
    return 0


def set_tone(kind: str, value: int) -> int:
    lo, hi = (LIGHTNESS_MIN, LIGHTNESS_MAX) if kind == "lightness" else (CONTRAST_MIN, CONTRAST_MAX)
    if not lo <= value <= hi:
        return unavailable(f"{kind} {value} out of range {lo}..{hi}", find_hidraw())
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, _Mode, Tone, _AutoClear = api()
        config = DisplayConfig.glider_standard()
        display = Display.new_with_config(config)
        current = read_tone(display)
        lightness, contrast = current if current is not None else (0, 0)
        if kind == "lightness":
            lightness = value
        else:
            contrast = value
        # get_tone returns None on older firmware; default to 0 for the
        # untouched value in that case (matches the OSD power-on defaults).
        display.set_tone(Tone(lightness, contrast))
    except Exception as exc:
        return unavailable(f"could not set {kind} to {value}: " + str(exc), nodes)
    emit({
        "ok": True,
        "connected": True,
        "tone": {"lightness": lightness, "contrast": contrast, "source": "device"},
        "modes": list(MODE_NAMES),
    })
    return 0


def set_autoclear(field: str, label: str) -> int:
    """Set one auto-clear setting by its human label (e.g. Adaptive, 5 min, Often).

    The other two fields are read back from the device first, so a single
    setting can be changed without touching the rest — mirroring the OSD.
    """
    tables = {"mode": AC_MODES, "interval": AC_INTERVALS, "threshold": AC_THRESHOLDS}
    table = tables[field]
    if label not in table:
        return unavailable(
            f"unknown auto-clear {field} '{label}'; expected one of: " + ", ".join(table),
            find_hidraw(),
        )
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, _Mode, _Tone, AutoClear = api()
        config = DisplayConfig.glider_standard()
        display = Display.new_with_config(config)
        current = read_autoclear(display)
        if current is None:
            return unavailable("device firmware does not support auto-clear read-back", nodes)
        fields = ("mode", "interval", "threshold")
        values = dict(zip(fields, current))
        values[field] = table.index(label)
        display.set_autoclear(AutoClear(values["mode"], values["interval"], values["threshold"]))
        emit({
            "ok": True,
            "connected": True,
            "autoclear": {
                "mode": _indexed(AC_MODES, values["mode"]),
                "interval": _indexed(AC_INTERVALS, values["interval"]),
                "threshold": _indexed(AC_THRESHOLDS, values["threshold"]),
                "source": "device",
            },
            "autoclearAvailable": True,
            "modes": list(MODE_NAMES),
        })
        return 0
    except Exception as exc:
        return unavailable(f"could not set auto-clear {field} to {label}: " + str(exc), nodes)


def redraw() -> int:
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, _Mode, _Tone, _AutoClear = api()
        config = DisplayConfig.glider_standard()
        display = Display.new_with_config(config)
        # Hard full-screen refresh: flashes black->white to clear ghosting.
        # Does not change the active refresh mode.
        display.redraw(config.full_screen())
    except Exception as exc:
        return unavailable("could not redraw the display: " + str(exc), nodes)
    emit({"ok": True, "connected": True, "redrawn": True, "modes": list(MODE_NAMES)})
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Control a Modos Glider display")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="emit JSON status")
    mode_parser = sub.add_parser("set-mode", help="set a full-screen refresh mode")
    mode_parser.add_argument("mode", choices=MODE_NAMES)
    tone_parser = sub.add_parser("set-lightness", help="set lightness (device read-back of the other value)")
    tone_parser.add_argument("value", type=int)
    contrast_parser = sub.add_parser("set-contrast", help="set contrast (device read-back of the other value)")
    contrast_parser.add_argument("value", type=int)
    ac_parser = sub.add_parser("set-autoclear", help="set an auto-clear setting (mode, interval or threshold) by label")
    ac_parser.add_argument("field", choices=("mode", "interval", "threshold"))
    ac_parser.add_argument("value", help="e.g. Off/Adaptive/Fixed, 1/5/15 min, Sometimes/Occasionally/Often")
    sub.add_parser("redraw", help="force a hard full-screen refresh to clear ghosting")
    args = parser.parse_args()
    if args.command == "status":
        return status()
    if args.command == "redraw":
        return redraw()
    if args.command == "set-lightness":
        return set_tone("lightness", args.value)
    if args.command == "set-contrast":
        return set_tone("contrast", args.value)
    if args.command == "set-autoclear":
        return set_autoclear(args.field, args.value)
    return set_mode(args.mode)


if __name__ == "__main__":
    raise SystemExit(main())
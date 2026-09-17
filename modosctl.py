#!/usr/bin/env python3
"""Small JSON CLI for the Modos Glider API.

The controller protocol currently has a setter but no mode getter.  Therefore
``status`` reports the last successfully requested mode stored locally; it
never presents that value as a hardware read-back.

``redraw`` forces the device to do a hard full-screen refresh (black to
white) to clear accumulated ghosting, matching the Dev Kit's third physical
button.

``set-mode`` switches the active refresh mode and immediately performs the
same hard full-screen redraw, so the display is redrawn cleanly under the new
mode instead of keeping the previous rendering.
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


def api() -> tuple[Any, Any, Any]:
    try:
        from glider_api import Display, DisplayConfig, Mode
        return Display, DisplayConfig, Mode
    except ImportError as exc:
        raise RuntimeError(
            "glider_api is not installed for " + sys.executable
            + "; install it with: " + sys.executable + " -m pip install ~/github/glider-api"
        ) from exc


def status() -> int:
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, _Mode = api()
        # Opening verifies hidapi can actually claim the matching USB device.
        Display.new_with_config(DisplayConfig.glider_standard())
    except Exception as exc:
        return unavailable("could not open the Modos HID device: " + str(exc), nodes)
    saved = local_state()
    emit({
        "ok": True,
        "connected": True,
        "hidraw": [str(node) for node in nodes],
        "mode": saved.get("mode", "unknown"),
        "modeSource": "local-state (the current glider-api has no mode getter)",
        "modes": list(MODE_NAMES),
    })
    return 0


def set_mode(name: str) -> int:
    if name not in MODE_NAMES:
        return unavailable("unknown mode '" + name + "'", find_hidraw())
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, Mode = api()
        config = DisplayConfig.glider_standard()
        display = Display.new_with_config(config)
        display.set_mode(getattr(Mode, name), config.full_screen())
        display.redraw(config.full_screen())
        write_state(name)
    except Exception as exc:
        return unavailable("could not set " + name + ": " + str(exc), nodes)
    emit({"ok": True, "connected": True, "mode": name, "modes": list(MODE_NAMES)})
    return 0


def redraw() -> int:
    code, nodes = require_device()
    if code:
        return code
    try:
        Display, DisplayConfig, _Mode = api()
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
    sub.add_parser("redraw", help="force a hard full-screen refresh to clear ghosting")
    args = parser.parse_args()
    if args.command == "status":
        return status()
    if args.command == "redraw":
        return redraw()
    return set_mode(args.mode)


if __name__ == "__main__":
    raise SystemExit(main())
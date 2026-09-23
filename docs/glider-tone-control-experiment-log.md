# Glider tone control over USB HID — experiment log

Date: 2026-09-22
Status: **experiment concluded — screen recovered by flashing stock release 1.1.1; all work preserved on local `tone-control` branches (nothing pushed)**
Upstream issue: https://github.com/Modos-Labs/glider-api/issues/7

> **Outcome summary:** Device read-back (GETTONE/GETMODE/GETSIGNAL) was
> verified working on hardware with the custom firmware. The SETLIGHTNESS
> setter was accepted by the firmware but the change did not persist, and a
> subsequent power cycle left the video path dead (MCU/USB alive). Flashing
> the stock 1.1.1 release fully recovered the screen, confirming the fault
> was in the custom build. Root cause not yet identified; prime suspect is
> `config_save()` (external-flash write) executed in the USB task context.

This document records everything we learned, implemented, and tried while adding
host-controllable lightness/contrast (and state read-back) to the Modos Glider
controller. It is written so that either of us (or the Modos developers) can pick
up exactly where we left off.

---

## 1. Goal

The Modos Paper Dev Kit's lightness and contrast can only be changed from the
physical buttons via the OSD menu. We wanted them scriptable from the host, so
they can be automated (time-of-day, theme changes) from the
`omarchy-modos-eink` plugin. Tracked upstream as glider-api issue #7, which we
filed earlier. With no developer response yet, we attempted the change ourselves —
the hardware design, gateware, and firmware are all open source.

## 2. What we learned about the system (all verified in source)

Firmware repo: https://github.com/Modos-Labs/Glider (mirror of GitLab
`zephray/Glider`), default branch `main`.

### 2.1 Where lightness/contrast live

- `fw/User/config.h` — `config_t` has `int lightness;` and `int contrast;`,
  persisted to the external SPI flash (`config.bin` inside SPIFFS) by
  `config_save()`. Survives power cycles and re-flash of the MCU firmware.
- `fw/User/tone_lut.c` — `tone_lut_build_y(lightness, contrast, lut)` builds a
  256-entry tone LUT. Valid ranges (clamped): lightness −3…+3, contrast −1…+6.
  These match the OSD menu steps exactly.
- `fw/User/caster.c` — `caster_set_tone(lightness, contrast)` builds the LUT and
  streams it to the FPGA (`CSR_TONE_ADDR`/`CSR_TONE_WR`). **Takes effect live,
  no redraw needed.**
- Apply path used by the OSD menu (`fw/User/ui.c`): set `config.lightness` /
  `config.contrast`, `config_save()`, `caster_set_tone(...)`. The serial shell
  (`fw/User/shell/shell_cmds.c`) also calls `config_save()` from its own task,
  so flash writes from multiple tasks are established practice.

### 2.2 USB HID protocol (as of upstream `ed94ef7`)

- Control channel: TinyUSB HID generic IN/OUT, report ID 5
  (`REPORT_ID_CONTROL`), 64-byte reports.
- Out packet: `[report_id][cmd][param:u16 LE][x0][y0][x1][y1][id:u16][crc16]`
  — CRC is XMODEM over bytes 1..13 (report ID excluded).
- In packet (response): byte 0 = report ID, byte 1 = return code
  (`0x55` success, `0x00` general fail, `0x01` checksum fail), byte 2 = echoed
  cmd, byte 3 = echoed param LSB, bytes 4–5 echo id, bytes 6–7 = expected CRC.
  Bytes 8+ were **reserved/zero — free space for getter payloads.**
- `tud_hid_set_report_cb` in `fw/User/usbapp.c` dispatches commands:
  `0x00 RESET, 0x01 POWERDOWN, 0x02 POWERUP, 0x03 SETINPUT, 0x04 REDRAW,
  0x05 SETMODE, 0x06 NUKE, 0x07 USBBOOT, 0x08 RECV`.
- `tud_hid_get_report_cb` is an unimplemented stub, but the descriptor is a
  generic IN/OUT — read-back is possible without changing the USB descriptor
  by writing payload bytes into the response report.

### 2.3 Task model (matters for concurrency)

`startup_task` runs boot (flash ID → SPIFFS → config → video bridges → power →
UI init) and later becomes the serial shell. Separately created tasks: USB
device, USB PD, UI (buttons/OSD), key scan, power monitor, housekeeping.
`config` is a single global `config_t` shared by all of them.

## 3. What we implemented

Repo: `~/Github/Glider`, branch `usb-tone-control`, commit `511ad59` (local
only, never pushed). Host side: `~/Github/glider-api` (uncommitted working
tree) + the plugin (modosctl.py, Service.qml, Panel.qml — also local only).

### 3.1 New firmware commands

| Value | Name | Direction | Payload |
|---|---|---|---|
| `0x09` | `SETLIGHTNESS` | host→dev | `param` = signed int16, clamped/validated −3…+3 |
| `0x0A` | `SETCONTRAST` | host→dev | `param` = signed int16, validated −1…+6 |
| `0x0B` | `GETTONE` | dev→host | response byte 8 = lightness (i8), byte 9 = contrast (i8) |
| `0x0C` | `GETMODE` | dev→host | response byte 8 = mode ordinal (`update_mode_t`) |
| `0x0D` | `GETSIGNAL` | dev→host | response byte 8 = raw input-status byte |

- New return code `USBRET_BADVALUE = 0x02` for out-of-range tone values.
- Setters run the OSD's exact apply path (`config_save()` +
  `caster_set_tone()`), guarded by a new `usb_tone_lock` mutex, because the OSD
  and shell also touch these fields (all from separate tasks).
- Getters are collected in the callback and stamped into the response's
  reserved bytes (8/9). The HID report descriptor is **unchanged**.
- `GETMODE` reads `config.update_mode`, which the UI keeps current (menu
  commits, K1 cycling). A `usbapp_mode_changed` volatile flag lets the UI task
  re-sync its own mode index when the *host* changes the mode, so the K1
  "next mode" button doesn't restart from a stale index.

### 3.2 Host side (glider-api + plugin)

- `Tone` pyclass/C struct (lightness, contrast i8), `Display.set_tone()` —
  range-checked client-side, sends SETLIGHTNESS then SETCONTRAST —,
  `Display.get_tone()`, `Display.get_mode()`, `Display.get_signal_status()`,
  C API `glider_set_tone/glider_get_tone/glider_get_mode/
  glider_get_signal_status`, new `parse_response` code 0x02 mapping.
  13 cargo tests pass (packet layout regression tests added for the new
  commands). Venv binding rebuilt.
- `modosctl.py`: new `set-lightness N` / `set-contrast N` subcommands (they
  read back the untouched value first, so the pair always stays consistent),
  `status` now reports `tone` and device read-back `mode` when firmware
  supports it, with graceful fallback (`tone: null`,
  `modeSource: "local-state ..."`) on stock firmware.
- Plugin UI: TONE section in the panel with themed −/+ steppers; steppers are
  hidden (and values shown as `—`) until the device answers a GETTONE, so
  nothing looks broken on stock firmware. Service.qml clamps to the device's
  advertised ranges and optimistically updates before the helper confirms.

## 4. Build and flash — what worked

- **CubeIDE 2.2.0's newer GCC breaks the upstream `usbpd` stack**
  (`DECLARE_HOOK`/`DECLARE_DEFERRED` macros, `return;` in non-void — GCC 14
  hard-errors on these). **CubeIDE 2.0.0 (as the docs pin) builds clean:
  0 errors, ~55 pre-existing warnings.** Build:
  `STM32CUBEIDE_BIN=/opt/st/stm32cubeide_2.0.0/stm32cubeide scripts/build_mcu.sh dev build/dev/mcu`
  → `glider_ec_rtos_dev.bin` (111904 bytes; fits the 128 KB internal flash).
- Flash: hold K1 (button nearest USB-C) while plugging in → device shows as
  `0483:df11`; then
  `dfu-util -a 0 -i 0 -s 0x08000000:leave -D glider_ec_rtos_dev.bin`.
  The final "Error during download get_status" after `:leave` is benign
  (device reboots mid-poll). Needs udev rule for `0483:df11` (see §7).
- First boot after DFU-exit re-enumerates as `1209:ae86` but the user reports
  a full unplug/replug is normally needed to start video; treat DFU-exit as
  not-final.

## 5. What worked with our firmware (verified on hardware)

- `GETTONE` returns the true persisted values: `{lightness: 1, contrast: 0}`
  — values previously set from the OSD menu, read back over USB. ✔
- `GETMODE` returns the real current mode (`FastMonoBlueNoise`,
  `modeSource: "device"`). ✔ — this retires the plugin's local-state
  workaround entirely.
- `GETSIGNAL` works (used in debugging; see §6). ✔
- Serial console, HID, shell all alive; config reads intact (full 1600×1200
  timing from `setcfg get`). ✔

## 6. What failed and the debugging timeline

1. `set-lightness -1` was **accepted** (device echoed `USBRET_SUCCESS` and the
   value) but a later read-back still returned the old value → the state
   change didn't stick.
2. User unplugged/replugged (their normal cold-boot flow) → **screen now
   completely dead**; buttons unresponsive; **green heartbeat LED still
   blinking** (green = normal per USAGE.md; red = fault).
3. Diagnostics gathered (`/tmp/shellcmd.py`, `/tmp/shellsession.py`,
   `/tmp/bootlisten.py` helpers talk to `/dev/ttyACM0` at 115200):
   - `ver` → our build (0.1, Sep 22 2026 18:37:38, Git ed94ef7). Shell alive.
   - `power` → `state: active`, no suspend. Not a suspend issue.
   - `syslog` is a *live/incremental* log (new lines only). Successive reads
     advanced through the boot log one line at a time:
     `System starting` → `Serial number: 0036004a...` →
     `Delay loop calibrated` → `SPI Flash Mfg ID: ef` … then no further
     progress lines on the final long read.
   - Full correct panel config from `setcfg get` proves config load worked at
     some point; `GETSIGNAL` returns 0x00 (no LOST/RESET bits).
4. Working hypothesis (unproven): boot never reaches FPGA bitstream load /
   video init, or wedged somewhere in external-flash write state after the
   `config_save()` triggered by the failed set. A 60 s full power drain did
   **not** recover it. The MCU and USB are healthy; the display/video path is
   not driving.

   Note on timing: the USB SETMODE/REDRAW path (`caster_setmode`,
   `caster_redraw`) has always run fine from the USB task context. The
   difference with our new commands is `config_save()` (SPIFFS erase/write on
   the external flash) in the same context — consistent with the failure, but
   **not yet proven**; possible also that a latent upstream bug (e.g. in
   `config_validate_loaded` / SPIFFS) was triggered.

## 7. Recovery

Rollback is always possible: the DFU bootloader is in the STM32 ROM and cannot
be erased by software.

1. Download the stock binary release in a **browser** (GitLab uploads are
   Cloudflare-protected against CLI tools):
   `https://gitlab.com/zephray/glider/-/uploads/63c7b2bdcb3b12bd8a076e5501182a45/1.1.1.tar.gz`
2. Extract; inside is `glider_ec_rtos.bin` (+ FPGA bitstreams, fonts, config —
   we only needed the MCU bin; the config.bin on the device was intact).
3. Hold K1 while plugging in (DFU), then
   `dfu-util -a 0 -i 0 -s 0x08000000:leave -D glider_ec_rtos.bin`.
4. **Result: screen recovered immediately — no unplug/replug was even
   needed after DFU-exit.** Video, buttons and OSD all back to normal on
   stock 1.1.1, which confirms the fault was in the custom build, not the
   hardware or the device's persisted config.

Note: the stock 1.1.1 MCU binary is built from a slightly newer upstream
(`16bdb70c`) than the firmware source we patched (`ed94ef7`, current GitHub
`main`). A diff between those two commits is a sensible first step before
rebasing the tone patch.

udev rules needed on the host (installed):

```
SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="df11", MODE="0666", TAG+="uaccess"
```

(the plugin's existing `69-modos-glider.rules` already covers `1209:ae86`)

Serial port access for debugging: `sudo chmod 666 /dev/ttyACM0` (resets on
replug) or a udev rule for the CDC ACM interface.

## 8. Next steps

- [x] Flash stock 1.1.1 → screen recovered (fault isolated to our build).
- [ ] Diff upstream `ed94ef7` (our base) vs `16bdb70c` (stock 1.1.1) for
      fixes we missed — this is now the *first* suspect for the failure.
- [ ] If the diff doesn't explain it: rebuild our patch on `16bdb70c` with
      `config_save()` removed from the tone setters (defer saves via a flag
      consumed by the UI/housekeeping task) → retest set-lightness with a
      backup monitor attached and a short timeout before any power cycle.
- [ ] Whatever the outcome: report findings (firmware patch, protocol,
      debugging data) on glider-api issue #7; the command design itself
      (ranges, response byte layout) is worth keeping regardless.
- [x] Host-side work (glider-api, modosctl, plugin UI) is complete and
      backwards-compatible — it degrades gracefully on stock firmware and
      needs no further changes unless the wire format changes in review.
      Preserved on the `tone-control` branch of both repos.

## 9. Repository state after the experiment

| Repo | Branch | State |
|---|---|---|
| `~/Github/Glider` | `usb-tone-control` (`511ad59`) | firmware patch; `main`/`master` untouched at `ed94ef7` |
| `~/Github/glider-api` | `tone-control` (`fcf04da`) | host API work; `main` untouched at pinned `b80cd7e` |
| plugin | `tone-control` (`c13b061`) | tone UI + helper + this log; `master` clean at `f0b51a1` |

The venv binding was rebuilt from the `tone-control` branch during testing;
rebuild it from the pinned `main` after checking out to restore the exact
plugin-README state (`PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 pip install
--force-reinstall --no-deps ~/Github/glider-api`).

Nothing has been pushed anywhere, per the ground rule for this experiment.

## 10. Artifacts

- `~/Github/Glider` branch `usb-tone-control`, commit `511ad59` (firmware patch)
- `~/Github/glider-api` branch `tone-control`, commit `fcf04da` (host API)
- plugin branch `tone-control`, commit `c13b061` (helper + panel + this log)
- debug helpers: `/tmp/shellcmd.py`, `/tmp/shellsession.py`,
  `/tmp/bootlisten.py` (serial console tools; recreate from this doc if lost)
- build log: `/tmp/mcu-build-2.0.0.log`
- stock release: `~/Github/1.1.1/` (keep until upstream hosts a backup;
  contains `firmware/flash.py` for full-package flashing)

---

# Round 2 (2026-09-23): getters on the fixed upstream base — success

## What changed the diagnosis

The GitHub mirror's `main` is NOT the upstream head. GitLab (`zephray/glider`)
is two commits ahead of the round-1 base (`ed94ef7`):

| Commit | Subject | Relevance |
|---|---|---|
| `42eabe1` | Log video input fallback diagnostics | also bumps the **Caster submodule** (`2f714ab` → `de58ccf`) |
| `16bdb70` | Fix EDID conformity; fix TMDS handling | 89 lines in `adv7611.c` (HDMI/TMDS receiver), 158 lines in `edid.c` — the exact video-input path that died in round 1 |

Stock 1.1.1 is built from `16bdb70`. Round 1's build predated the EDID/TMDS
fixes and the Caster bump — very plausibly the real cause of the round-1
freeze (screen blank, DP-3 "connected" but no monitor, USB alive), rather
than (or in addition to) the in-context `config_save()` theory.

## Branch restructuring

- `usb-tone-control` **rebased** onto `gitlab/main`; rebased cleanly (the
  upstream `ui.c` changes and ours touch different regions).
- Slimmed to **getters-only** — `SETLIGHTNESS`/`SETCONTRAST` and the
  `USBRET_BADVALUE` definition were removed; `GETTONE`/`GETMODE`/`GETSIGNAL`
  and the SETMODE re-sync remain. Result: commit `39d8289`.
- The full round-1 (setters) version is preserved as `usb-tone-control-full`.
- Submodule `Caster` aligned to `de58ccf` as required by the new base.

## Round 2 flash results

- Host tests pass; CubeIDE 2.0.0 build: 0 errors, 55 warnings (same as stock).
- Getters-only build flashed → video works, **unplug/replug cycles restore
  video cleanly** (the round-1 killer scenario, now passed repeatedly).
- Getters verified live: `get_tone` → lightness/contrast, `get_mode` →
  AutoNoDither, `get_signal_status` → 0x3c. Read-back values track OSD/menu
  changes and survive replugs.

## New bug found: `config_save()` never persisted anything

User reported tone changes (OSD menu) not surviving reboots — on the
getters-only build, which never writes config. Investigation via a
diagnostic-shell build (see below) and reading `fw/User/config.c`:

`config_save()` opened `config.bin` with `O_CREAT|O_TRUNC|O_WRONLY`, wrote,
**and never called `SPIFFS_close()`**. Consequences, all on stock firmware:

1. SPIFFS buffers writes in RAM; flash is only written on close. Unless a
   cache page happened to be evicted, the config write never reached flash —
   settings died at power-off. (Matches: device always booted lightness +1,
   the last value saved before the leak began... or factory-era luck.)
2. Every save leaked one of the 32 fd slots; eventually all saves failed
   silently (the function returned without logging).

Fix (`8bc935e`): close the file, check write result, log failures via
`syslog_printf`. Verified end-to-end: OSD tone change → read-back via
`get_tone` → `setcfg save` (shell) → `fs dump config.bin` shows content →
unplug/replug → device boots with the changed values (lightness 0,
contrast 1). Persistence now works for the first time.

Note: round 1's "config_save in USB context" theory is weakened — stock's
own `USBCMD_SETINPUT` handler also calls `config_save()` in USB context.
The setters remain unproven on hardware and stay deferred to round 3 with
the deferred-save design regardless.

## Diagnostic shell build

`GLIDER_DIAGNOSTIC_SHELL` (opt-in in `shell.c`) adds `fs ls/df/dump/format`,
`mem`, `i2c_probe`, `recv/send` (XMODEM/YMODEM), `sensor`, `setvolt`. It is
NOT defined in any build config by default. For this round we added the
define to `fw/.cproject` temporarily, built `dev2diag`, and reverted the
`.cproject` afterwards (the flag is not committed). The device currently
runs the diagnostic build — functionally identical plus maintenance shell.
Re-flash a lean build before any long-term use if desired.

Caution learned: the FPGA bitstream (`fpga.bit`), fonts and `config.bin`
live in the **same SPIFFS** — `fs format` would require re-flashing the
bitstream afterwards (stock 1.1.1 tarball at `~/Github/1.1.1/` works).

## Housekeeping

- All three repos' work branches are on GitHub: `cittadhammo/omarchy-modos-eink`
  (`tone-control`), forks `cittadhammo/glider-api` (`tone-control`) and
  `cittadhammo/Glider` (`usb-tone-control`, `usb-tone-control-full`).
- Serial console access: user added to `uucp` group (chmod 666 no longer
  needed after re-login); `/tmp/shellcmd.py` recreates the one-shot console
  helper (send command, print response).

## Round 3 plan (setters)

1. Re-add SETLIGHTNESS/SETCONTRAST on top of the getters commit.
2. Apply tone via LUT immediately, but **defer `config_save()` out of the
   USB handler** (flag for the config/caster context) — by design, not guess.
3. Same gentle test ladder: build → flash → video first → one setter →
   read-back → replug → reboot persistence.
4. Consider reporting upstream (issue #7): getters + the `config_save`
   bug fix are directly valuable to the project.

---

# Round 3 (2026-09-23): setters with deferred save — success

Branch `usb-tone-control-setters` (commit `5ff7792`) on top of the getters:
SETLIGHTNESS (0x09, −3…+3) / SETCONTRAST (0x0A, −1…+6) apply via the tone
LUT immediately and request the flash write through `config_request_save()`;
the UI task performs the actual SPIFFS write on its next loop (≤200 ms),
so USB context never touches flash and bursts coalesce.

Test ladder, all passed:
- video after flash; single setter (the exact operation that froze round 1)
  applied live — user visually confirmed the dim, no redraw flash;
- read-back 0 → −1; 6-set rapid burst with no hiccup or re-enumeration;
- unplug/replug: video restored, boots with host-set lightness −1 and
  OSD-set Typing mode — host-written config persists.

Plugin `master` merged the `tone-control` branch: panel now shows device
read-back tone/mode (`source: "device"`) and the tone steppers are live.

---

# Round 4 (2026-09-23): auto-clear control — success

Motivation: the Auto Clear settings (the most e-ink-native group in the OSD)
were the biggest remaining OSD-only feature. Branch `usb-ac-control`
(firmware `7392721`, glider-api `7337ccc`, plugin `8bca06e`) — all pushed
only after the user's live test pass.

## Firmware

Four new HID commands mirroring the OSD's Auto Clear submenu:

| Command | Value | Behavior |
|---|---|---|
| `SETACMODE` | `0x0E` | 0=Off, 1=Adaptive, 2=Fixed (range-validated) |
| `SETACINTERVAL` | `0x0F` | 0=1 min, 1=5 min, 2=15 min |
| `SETACTHRESHOLD` | `0x10` | 0=Sometimes, 1=Occasionally, 2=Often |
| `GETAC` | `0x11` | All three in reserved response bytes 8/9/10 |

Apply path: setters write `config`, raise `usbapp_ac_changed`, and defer the
flash write via `config_request_save()`; the UI task consumes the flag at the
top of its loop, re-syncs its local `autoclear` mirror and resets the
timers/counters — identical pattern to `usbapp_mode_changed` (round 3).
Build 0 errors / 55 warnings (stock count), host tests pass.

## Host side

glider-api `ac-control`: `AutoClear` pyclass + `get_autoclear()` /
`set_autoclear()` (all fields range-checked client-side too), packet-layout
tests, 15/15 pass. Plugin: `modosctl set-autoclear <field> <label>` reads the
two untouched fields back from the device first (OSD-equivalent semantics);
`status` reports `autoclear` + `autoclearAvailable`; the panel shows the AC
section only when the firmware answers `GETAC`.

## UI evolution (user-driven)

First design (one row per setting with a ⟳ cycle button) was rejected:
too tall on the 1600×1200 panel, options invisible, symbol unclear.
Final design: every option rendered as a small clickable chip with the
active one highlighted; interval row only in Fixed mode, threshold row only
in Adaptive; both tone steppers share one line (Contrast right-aligned);
all rows share one `labelColumnWidth` so controls start vertically aligned.
Section title dropped entirely.

## Testing (all passed, user hands + agent scripts)

- Flash → video back; `GETAC` baseline = Adaptive/5 min/Occasionally (defaults).
- Setter ladder: each field flipped and read back, restored, device alive.
- User tests: (1) Fixed/1-min produces a visible once-a-minute refresh;
  (2) chips ↔ OSD round-trip agrees within one poll; (3) adaptive clears
  behave as before; (4) unplug/replug boots with the saved AC values;
  (5) rapid chip clicking — no hiccup.
- **Bug found in user testing:** adding `AutoClear` to `modosctl.api()`'s
  return tuple (4→5) broke `set_tone`/`set_mode` call sites that still
  unpacked 4 values ("too many values to unpack, expected 4, got 5").
  Root cause: my smoke tests exercised only the new paths + status, not the
  tone/mode setters. Fix trivial; afterwards all six CLI commands were
  exercised green. Lesson recorded: when changing a shared helper's
  signature, exercise every consumer.


# Blue Merle (GL-E750 / Mudi v2) -> Puli AX (GL-XE3000) Porting Plan

> **For Codex:** Execute this plan task-by-task (verification after each task). If you dispatch subagents, keep one task per agent.

**Goal:** Port the `blue-merle` OpenWrt package (originally validated on GL.iNet GL-E750V2 “Mudi v2”) to run safely and correctly on GL.iNet GL-XE3000 “Puli AX”, preserving the privacy features that make sense on the new hardware and explicitly handling features that are hardware/firmware-dependent (especially IMEI writes).

**Architecture:** Split device-specific assumptions out of the scripts into small “capability probes” (What modem? Which AT port? Is there a screen/MCU? Where is the client database?) and route behavior through a single hardware-adaptation layer. Keep the package as a pure-script OpenWrt package (no cross-compilation needed), but make it resilient across GL.iNet SDK/OpenWrt variants.

**Tech Stack:** OpenWrt/GL.iNet SDK, POSIX shell (`/bin/sh`, `ash`), UCI, LuCI (client-side JS + rpcd ACL), Python3 + pyserial, GL.iNet helpers (`gl_modem`, `gl_util.sh`, `mcu_send_message` when present).

---

## 1) What This Repo Is (Code Analysis)

This repo is an OpenWrt package that installs scripts and a LuCI page. There is no compiled code (`Build/Compile` is empty in `Makefile`).

### 1.1 Package Composition (entrypoints)

**Packaging / install hooks**
- `Makefile`
  - Declares dependencies: `luci-base`, `gl-sdk4-mcu`, `coreutils-shred`, `python3-pyserial`.
  - Preinstall (`preinst`) hard-blocks non-GL-E750 by checking `/proc/cpuinfo` for `GL.iNet GL-E750`, and prompts on unknown `glversion`.
  - Postinstall (`postinst`) sets the physical switch function: `uci set switch-button.@main[0].func='sim'`.

**Boot-time privacy features**
- `files/etc/init.d/blue-merle`
  - Runs early (`START=10`) to:
    - Randomize BSSIDs by writing `wireless.@wifi-iface[0|1].macaddr` and committing.
    - Randomize WAN MAC and “MAC clone” used for upstream WiFi.
  - The functions are in `files/lib/blue-merle/functions.sh`.
- `files/etc/init.d/volatile-client-macs`
  - Runs earlier (`START=9`) to move the client MAC database from flash to RAM:
    - Copies `/etc/oui-tertf/client.db` into a tmpfs-mounted directory, shreds the original, then mounts tmpfs over `/etc/oui-tertf`.

**IMEI change flows**
- CLI flow:
  - `files/usr/bin/blue-merle`
  - Uses `gl_modem` AT commands (`AT+CFUN`, `AT+GSN`, `AT+CIMI`, `AT+QPOWD`) and Python IMEI generation to stage an IMEI change around a SIM swap.
  - Hard-requires `/dev/ttyUSB3` to exist (even though most actual AT I/O is done via `gl_modem`).
- Hardware-switch flow (2-stage):
  - `files/etc/gl-switch.d/sim.sh` dispatches:
    - `files/usr/bin/blue-merle-switch-stage1` (disable RF, set interim random IMEI, prompt “swap SIM”)
    - `files/usr/bin/blue-merle-switch-stage2` (reset modem, set final random IMEI, shutdown)
  - Uses MCU messaging (`mcu_send_message`) via `/lib/functions/gl_util.sh`, which is device/firmware-specific.

**LuCI UI**
- `files/www/luci-static/resources/view/blue-merle.js`
  - Calls `/usr/libexec/blue-merle` via `fs.exec()` / `fs.exec_direct()` to:
    - show IMEI/IMSI
    - do “SIM swap…” (disable modem + randomize IMEI + offer shutdown)
- `files/usr/libexec/blue-merle`
  - Implements the LuCI-called subcommands: `read-imei`, `read-imsi`, `random-imei`, `shutdown-modem`, `shutdown`.
- `files/usr/share/luci/menu.d/luci-app-blue-merle.json`, `files/usr/share/rpcd/acl.d/luci-app-blue-merle.json`
  - Adds menu entry and rpcd ACL for executing `/usr/libexec/blue-merle`.

### 1.2 Key Hardware/Firmware Assumptions in the Code

These are the exact assumptions that will likely break on Puli AX:

1. **Device gating**: preinst checks for `GL.iNet GL-E750` in `/proc/cpuinfo` and warns/blocks otherwise (`Makefile`).
2. **Modem AT port**: Python uses `TTY = '/dev/ttyUSB3'` at 9600 baud (`files/lib/blue-merle/imei_generate.py`), and CLI checks `/dev/ttyUSB3` exists (`files/usr/bin/blue-merle`).
3. **Modem vendor-specific IMEI write**: uses `AT+EGMR=1,7,"<imei>"` (Quectel LTE-series specific, may not exist/allow writes on RM520).
4. **GL.iNet MCU/display**: uses `/dev/ttyS0` JSON messages and `mcu_send_message` (Mudi has an OLED display; Puli AX appears to have LEDs, not an OLED).
5. **Switch integration**: assumes GL.iNet “switch-button” can be set to `func='sim'` and that `/etc/gl-switch.d/sim.sh` will be called.
6. **UCI layout**:
   - Assumes exactly two wifi-iface sections at indexes `[0]` and `[1]`.
   - Assumes `network.@device[1]` exists and is the WAN-facing device.
   - Assumes `glconfig.general.macclone_addr` exists.
7. **Client DB path**: assumes connected-client MAC db is `/etc/oui-tertf/client.db`.

Porting must remove or probe these assumptions.

---

## 2) Mudi v2 Hardware/Software Stack (Reference Baseline)

From GL.iNet’s Mudi v2 product info (GL-E750 / “Mudi V2” section on the GL-E750 page: `https://www.gl-inet.com/products/gl-e750/`):
- Model: GL-E750V2 (Mudi v2).
- CPU/SoC: QCA9531 @ 650MHz.
- Memory/storage: DDR2 128MB; NOR 16MB + NAND 128MB.
- Display/UI hardware: 0.96-inch OLED display; has a “Toggle button”.
- Interfaces: USB 2.0, Nano SIM slot, MicroSD slot, power button; Ethernet is via docking station and is Fast Ethernet (10/100).
- Cellular module class: “CAT4 Module … or CAT6 Module …” (Mudi units can vary; blue-merle’s current EP06 assumption is a Cat6-specific path).

From this repo’s own README:
- Baseband/modem noted for Mudi (v1/v2 context): Quectel EP06-E/A series LTE Cat 6 module; IMEI write uses `AT+EGMR`. (Repo statement; treat as “blue-merle’s validated assumption”.)

**Implication for blue-merle v2:** the current implementation is optimized for:
- ath79/mips_24kc class system
- EP06-style USB serial port layout and AT commands
- an MCU/display path for user prompts
- GL.iNet SDK4 “gl-switch” behavior with a physical toggle.

---

## 3) Puli AX Hardware/Software Stack (Port Target)

From GL.iNet’s Puli AX (GL-XE3000) product page (`https://www.gl-inet.com/products/gl-xe3000/`):
- Model: GL-XE3000 (Puli AX).
- CPU: “MediaTek Dual-core @ 1.3GHz”.
  - (GL-XE3000 page doesn’t name the exact SoC. Related GL-X3000 materials list MT7981A @ 1.3GHz, which is likely the same family, but **must be confirmed on-device**: `https://openwrt.org/toh/gl.inet/gl-x3000`.)
- Memory/storage: DDR4 512MB / eMMC 8GB.
- Modem module: Quectel RM520N-GL (5G NR).
- Firmware base: proprietary firmware based on OpenWrt 21.02, kernel 5.4.
- Physical UI: LEDs listed (Power/Battery/Internet/WiFi/Signal), not an OLED.
- SIM: dual nano SIM slots.
- eSIM: device is listed as supported by GL.iNet eSIM management docs (`https://docs.gl-inet.com/router/en/4/tutorials/how_to_use_esim_physical_card_with_glinet_routers/`).
- Ethernet: 2.5GbE WAN + 1GbE LAN.

**Implications for the port:**
- Architecture changes from MIPS (mips_24kc) to ARM64-class (very likely) with different kernel/userspace versions.
- Modem class changes from LTE Cat6 EP06 to 5G RM520N-GL, which may differ in:
  - which tty is the AT port
  - whether IMEI writes are permitted/locked
  - reset/shutdown behaviors
- The “show messages on OLED” flow likely does not exist; user interaction must move to LuCI + CLI output.
- Dual-SIM behavior likely involves different GPIO/MCU logic than Mudi.

---

## 4) Significant Differences (Mudi v2 vs Puli AX) and What They Break

This section is the “reference to every significant difference between the models” and maps each difference to code impact.

### 4.1 CPU / Architecture / OpenWrt Base

- Mudi v2: QCA9531 (MIPS-class), per GL.iNet GL-E750 page.
- Puli AX: MediaTek dual-core 1.3GHz (likely ARM64-class), OpenWrt 21.02-based (kernel 5.4), per GL.iNet GL-XE3000 page.

Breakage risk:
- The preinst device check will reject Puli AX.
- Binary package arch changes (mips_24kc -> arm64-ish), so releases must be built for the new target.
- Package dependencies might differ by GL.iNet SDK generation and OpenWrt version (especially Python3 packaging and `coreutils-shred` availability).

### 4.2 Modem Module / AT Command Surface

- Mudi: EP06-E/A LTE module (repo assumption) with IMEI write via `AT+EGMR`.
- Puli AX: RM520N-GL 5G module, per GL.iNet GL-XE3000 page.

Breakage risk:
- `AT+EGMR` support is not guaranteed on RM520N-GL; even if present, IMEI writes may be blocked by firmware/carrier policy.
- `/dev/ttyUSB3` may not exist, or may not be the AT port.
- Baud rate and port naming may differ (`ttyUSB*` vs `ttyACM*`), depending on USB composition.
- RM520-class modules often expose multiple USB functions (AT, diag, modem/NMEA), so “pick the right tty” needs probing, not hardcoding.

### 4.3 User Interaction Hardware (OLED+MCU vs LEDs)

- Mudi v2: OLED display, per GL.iNet GL-E750 page.
- Puli AX: LEDs listed, no OLED mentioned (GL.iNet GL-XE3000 page).

Breakage risk:
- Writing JSON to `/dev/ttyS0` and `mcu_send_message` prompts will not produce user-visible guidance (or might not exist).
- The “toggle switch staged flow” UX is likely not transferable; the plan should pivot to LuCI-first + CLI.

### 4.4 SIM Hardware (Single SIM vs Dual SIM + eSIM compatibility)

- Mudi v2: single SIM slot, per GL.iNet GL-E750 page.
- Puli AX: dual SIM slots (GL.iNet GL-XE3000 page); supported by GL.iNet eSIM management docs (`https://docs.gl-inet.com/router/en/4/tutorials/how_to_use_esim_physical_card_with_glinet_routers/`).

Breakage risk:
- The Mudi-specific “swap SIM now” flow may not match Puli’s dual-SIM standby behavior; you may need:
  - an explicit “select SIM1/SIM2” control
  - logic to handle eSIM presence (if configured) and prevent IMEI leak through eSIM tooling.

### 4.5 Networking/WiFi Model

- Puli AX is Wi-Fi 6 and may have different UCI section ordering and device naming than the Mudi.

Breakage risk:
- Hardcoded `wireless.@wifi-iface[0|1]` and `network.@device[1]` is brittle across models.
- “MAC clone” setting location may differ or be absent.

### 4.6 Client MAC Database Location and Services

- Mudi implementation assumes `/etc/oui-tertf/client.db` and that `gl_clients` is the service managing it (preinst stops it, postinst starts it).

Breakage risk:
- Puli AX may store the client list elsewhere or use different service names.
- Mounting tmpfs over `/etc/oui-tertf` could break Puli’s UI if the path is different or if other files in that directory are required.

---

## 5) Porting Strategy (High-Level)

### 5.1 Define “Capabilities” and Probe at Runtime

Implement a small probe layer that answers:
- Which GL.iNet device is this? (model string)
- Is `gl_modem` present and usable?
- What is the modem AT port? (if we need raw serial)
- What modem vendor/model is attached? (`AT+CGMI`, `AT+CGMM`, `AT+GMR`)
- Does the modem accept IMEI writes? (dry-run detection or guarded attempt)
- Is there an MCU/display endpoint? (`mcu_send_message` present; is `/dev/ttyS0` usable)
- Where is the connected-client database and what service writes it?
- Which wireless interfaces should have macaddr randomized?
- Which network interface is WAN / upstream MAC clone?

Everything else should be built on top of those probes.

### 5.2 Degrade Gracefully When IMEI Writes Aren’t Possible

For Puli AX the hard requirement must be:
- Always support “RF off / RF on” and IMSI/IMEI reads (if possible).
- Only enable “set IMEI” if modem/firmware supports it; otherwise hide/disable that UI action and document why.

### 5.3 Prefer LuCI + CLI; Treat “Switch” as Optional

Given the likely lack of OLED/toggle parity on Puli AX, porting should:
- keep CLI (SSH) workflow
- keep LuCI workflow
- make switch integration conditional (only if the GL.iNet `gl-switch` hook exists and a suitable button is present).

---

## 6) Concrete Implementation Plan (Bite-Sized Tasks)

Each task below is intentionally small and verifiable on a Puli AX device.

### Task 1: Create a “Device Probe” Library

**Files:**
- Create: `files/lib/blue-merle/probe.sh`
- Modify: `files/lib/blue-merle/functions.sh`
- Modify: `files/usr/bin/blue-merle`
- Modify: `files/usr/libexec/blue-merle`
- Modify: `files/usr/bin/blue-merle-switch-stage1`
- Modify: `files/usr/bin/blue-merle-switch-stage2`

**Steps:**
1. Implement helper functions in `files/lib/blue-merle/probe.sh`:
   - `bm_model()` -> reads `/tmp/sysinfo/model` if present; else `ubus call system board`.
   - `bm_has_cmd <name>`
   - `bm_has_mcu()` -> checks for `mcu_send_message` and writable `/dev/ttyS0`.
   - `bm_modem_at_device()` -> returns a best-effort AT port (see Task 2).
   - `bm_modem_ident()` -> returns `CGMI/CGMM/GMR` strings via `gl_modem` or raw serial.
2. Source `probe.sh` from `functions.sh` and the scripts that need it.
3. Add a `BM_LOG_TAG=blue-merle` logger helper for consistent syslog.

**Verification (on-device):**
- Run: `. /lib/blue-merle/probe.sh; bm_model; bm_has_cmd gl_modem; bm_modem_ident`
- Expected: prints a model string and some modem identification without errors.

### Task 2: Remove Hardcoded `/dev/ttyUSB3` and Discover the Modem AT Port

**Files:**
- Modify: `files/lib/blue-merle/imei_generate.py`
- Modify: `files/usr/bin/blue-merle`
- Modify: `files/usr/libexec/blue-merle`
- Modify: `files/lib/blue-merle/probe.sh` (from Task 1)

**Steps:**
1. Change `imei_generate.py` to accept `--tty` and `--baud` (default to current values).
2. Update shell scripts to pass the detected tty:
   - Prefer `gl_modem` for AT I/O when available (no tty needed).
   - Only use pyserial when IMEI write/read requires it.
3. Implement `bm_modem_at_device()` discovery:
   - If `gl_modem` exists: return empty and use `gl_modem`.
   - Else: iterate candidates `/dev/ttyUSB*` and `/dev/ttyACM*`, send `AT\r`, detect `OK`.

**Verification:**
- On Puli AX, ensure `blue-merle` no longer fails just because `/dev/ttyUSB3` doesn’t exist.

### Task 3: Abstract “Modem Operations” (Read IMEI/IMSI, RF Off, Reset)

**Files:**
- Modify: `files/lib/blue-merle/functions.sh`
- Modify: `files/usr/bin/blue-merle`
- Modify: `files/usr/bin/blue-merle-switch-stage1`
- Modify: `files/usr/bin/blue-merle-switch-stage2`
- Modify: `files/usr/libexec/blue-merle`

**Steps:**
1. In `files/lib/blue-merle/functions.sh`, replace direct `gl_modem AT ...` use with wrappers:
   - `BM_AT "<cmd>"` (uses `gl_modem` if present else raw serial)
   - `BM_READ_IMEI`, `BM_READ_IMSI`
   - `BM_RF_OFF` (CFUN=4), `BM_RF_RESET` (CFUN=0 then CFUN=4)
   - `BM_MODEM_POWEROFF` (prefer `AT+QPOWD` if supported; else fallback)
2. Ensure wrappers are tolerant of different modem firmware responses.

**Verification:**
- Run each wrapper on Puli AX and Mudi (if available) and confirm they behave as expected.

### Task 4: Make IMEI Writes Vendor/Model-Aware (and Optional)

**Files:**
- Modify: `files/lib/blue-merle/imei_generate.py`
- Modify: `files/usr/libexec/blue-merle`
- Modify: `files/www/luci-static/resources/view/blue-merle.js`
- Modify: `files/lib/blue-merle/probe.sh`

**Steps:**
1. Add modem detection:
   - Query vendor/model via `AT+CGMI` / `AT+CGMM`.
2. Gate the “Random IMEI” action:
   - If vendor/model is known to support `AT+EGMR` (EP06-style), enable.
   - If vendor/model is RM520N-GL, attempt a guarded capability check:
     - Try `AT+EGMR?` or a safe query variant if exists.
     - If not supported, surface “IMEI change unsupported on this modem/firmware” in LuCI.
3. If IMEI writes are supported, ensure `imei_generate.py` uses the correct command format per modem family.

**Verification:**
- On Puli AX:
  - If IMEI write is unsupported: LuCI should show IMEI/IMSI and allow RF-off/shutdown, but disable “random IMEI”.
  - If supported: confirm IMEI actually changes and persists after modem reset.

### Task 5: Replace MCU/OLED Messaging With LuCI/CLI Messaging on Puli AX

**Files:**
- Modify: `files/usr/bin/blue-merle-switch-stage1`
- Modify: `files/usr/bin/blue-merle-switch-stage2`
- Modify: `files/etc/gl-switch.d/sim.sh`
- Modify: `files/usr/libexec/blue-merle`

**Steps:**
1. Create `BM_NOTIFY "<msg>"`:
   - If MCU is present: `mcu_send_message`.
   - Else: `logger` + CLI stdout; and for LuCI, return stdout text.
2. Avoid writing to `/dev/ttyS0` directly unless probe confirms it is meaningful.

**Verification:**
- On Puli AX: stage scripts produce usable guidance via logs and LuCI output without assuming a screen.

### Task 6: Make MAC/BSSID Randomization Robust Across Different Wireless Configs

**Files:**
- Modify: `files/lib/blue-merle/functions.sh`
- Modify: `files/etc/init.d/blue-merle`

**Steps:**
1. Replace index-based UCI writes (`wireless.@wifi-iface[0]`, `[1]`) with iteration:
   - For each `wifi-iface` with `mode='ap'`, set `macaddr` to a generated unicast MAC.
2. Replace `network.@device[1]` with:
   - Find the device used by the WAN interface (e.g. `uci get network.wan.device` / `ifname` depending on syntax), then set its `macaddr`.
3. Make `glconfig.general.macclone_addr` conditional:
   - Only set it if the config exists on that firmware.

**Verification:**
- After reboot on Puli AX, verify BSSID and WAN MAC changed without breaking connectivity.

### Task 7: Port the “Volatile Client MAC DB” Feature Carefully

**Files:**
- Modify: `files/etc/init.d/volatile-client-macs`
- Modify: `Makefile` (pre/postinst service control)

**Steps:**
1. On a Puli AX test device, identify the actual client DB path and service:
   - Inspect UI/client-list feature; search for `client.db` paths.
2. Update the script to:
   - only act if the file exists
   - preserve required directory structure/files
   - avoid breaking the UI if the DB format/path differs.
3. In `Makefile`:
   - make stopping/starting `gl_clients` conditional (only if service exists).

**Verification:**
- On Puli AX: UI still shows connected clients; the DB is stored in tmpfs (volatile) and not persisted.

### Task 8: Update Packaging Metadata and Device Checks for GL-XE3000

**Files:**
- Modify: `Makefile`
- Modify: `README.md` (port notes)

**Steps:**
1. In `Makefile`:
   - Update `TITLE`/description to include GL-XE3000 support.
   - Replace hard block on `GL.iNet GL-E750` with:
     - allow list: `GL-E750*` and `GL-XE3000*`
     - or remove device block entirely and replace with capability probes + warnings.
2. Confirm dependencies available on Puli AX SDK (OpenWrt 21.02-based):
   - `python3`, `python3-pyserial`, `coreutils-shred`, `luci-base`.
3. Keep `gl-sdk4-mcu` optional if Puli AX doesn’t have MCU messaging.

**Verification:**
- `opkg install` succeeds on Puli AX without interactive abort.

### Task 9: Add Minimal Automated Checks (Non-Device)

**Files:**
- Create: `tests/test_imei_generate.py` (if you add a test harness)
- Create: `.github/workflows/ci.yml` updates (optional)

**Steps:**
1. Add a small Python unit test to validate:
   - IMEI generation produces 15 digits
   - Luhn check passes
   - deterministic mode stable for same IMSI
2. Add a lightweight shell lint step for scripts (optional).

**Verification:**
- CI passes; local `python3 -m pytest` passes.

---

## 7) On-Device Data Collection Checklist (Do This Before/While Porting)

Run these commands on a real GL-XE3000 and paste results into an issue/notes:
1. `cat /tmp/sysinfo/model; ubus call system board`
2. `cat /etc/glversion; opkg print-architecture`
3. `which gl_modem; gl_modem --help || true`
4. `ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true`
5. `for d in /dev/ttyUSB* /dev/ttyACM*; do echo "== $d"; timeout 2 sh -c "echo -e 'AT\\r' > $d"; done` (only if safe on your system)
6. `gl_modem AT 'AT+CGMI'; gl_modem AT 'AT+CGMM'; gl_modem AT 'AT+GMR'`
7. `ls -la /etc/oui-tertf /etc/oui-tertf/client.db 2>/dev/null || true`
8. `service | rg -n 'gl_clients|gl-tertf|tertf|client' || true`

This info drives Tasks 2/4/7 correctness.

---

## 8) Deliverables

1. An updated `blue-merle` package that installs and runs on GL-XE3000.
2. LuCI page that:
   - always shows IMEI/IMSI (when readable)
   - clearly indicates whether IMEI change is supported on that modem/firmware
   - supports “RF off / shutdown modem / shutdown router” safely
3. CLI workflow that does not assume `/dev/ttyUSB3` or Mudi-only display hardware.
4. Documentation updates in `README.md` describing Puli AX behavior and any limitations.

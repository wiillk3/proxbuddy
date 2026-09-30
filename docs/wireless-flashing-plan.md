# Wireless ARM flashing (PM5 over BLE / Wi-Fi)

Working plan for making ProxBuddy flash Proxmark5 ARM firmware (`fullimage.elf`,
later `bootrom.elf`) over BLE or Wi-Fi. BWM/ESP32 OTA is out of scope.

> **Status (2026-09-17):** Wi-Fi flashing works end to end. BLE flashing is
> parked and blocked in the UI — see "Amendment" under *Direction* below.

Repos (local `wireless-device-flashing` branches, not pushed):

- ProxBuddy: `/Users/williamkellner/d3v/proxmark/PM5/proxBuddy`
- pm3 fork: `/Users/williamkellner/d3v/proxmark/will/proxmark3`
- BWM fork: `/Users/williamkellner/d3v/proxmark/will/Proxmark5_BWM_esp32` — **no code changes**

Client version stays pinned to the IPA. Match this client; do not fetch “latest
firmware.” BYO `.elf` first. Hosted artifacts later.

---

## Problem

Stock bootrom is USB-only. After `CMD_START_FLASH` the AT32 resets into bootrom
while the ESP stays up at 921600. Without a BWM path in the bootrom, IAP packets
never land.

We added that path (`bootrom/bwm_boot.c`) and got as far as entering flash mode
and identifying the chip. The first *payload* write (`CMD_FINISH_WRITE`, block 0
of 158) times out. Earlier “progress” through ~block 14 was writing garbage.

Root cause: OLD frames are 544 raw bytes with **no magic, length, or CRC**. USB
CDC gets packet boundaries from `usb_poll_validate_length()`. The BWM link does
not.

ProxBuddy writes a 544-byte command as ATT chunks (~182 bytes at typical iOS
MTU). The ESP BLE RX callback rebroadcasts *exactly what it received* as a
`DATA_FORWARD` (8089) frame — no reassembly. The bootrom latches a “complete
packet” on each app_com frame and copies from offset 0.

Commands that only read `c->cmd` / `c->arg[0..2]` (first 32 bytes) appear to
work: `DEVICE_INFO`, `CHIP_TYPE`, `CHIP_INFO`, `BL_VERSION`, `START_FLASH`.
`CMD_FINISH_WRITE` is the first command that needs `c->d`. Chunks 2 and 3 become
garbage-cmd packets, hit `default:`, and are dropped.

The OS already got this right: `armsrc/bwm_forward.c` pushes `DATA_FORWARD`
payload bytes into a byte FIFO. The bootrom copy did not.

### What this is not

- Not “firmware too big.” Segment `0x4d364` fits 1 MB AT32 flash
  (`0x08004000–0x08100000`).
- Not an ESP firmware bug. A transparent pipe that preserves byte order but not
  Proxmark frame boundaries is a normal transport contract. TCP would do the
  same with luckier (larger) reads.
- Not solvable by MTU tuning. iOS ATT payload is well below 544.

### Bugs that looked like the root cause (still worth fixing)

These are real, but they were diagnosis noise on the way to the framing bug:

- Unknown / timed-out AT32 chip id defaulted to **256 KB** (`0x08040000`).
- `CMD_CHIP_TYPE` timeout stored `0`, which is `MAIN_CHIP_TYPE_AT91`. Client then
  sent AT91 addresses; AT32 bootrom NACKed (`0x00fe`). CHIP_INFO’s AT32 idcode
  decoded as “32K SRAM.”
- Accepting `CMD_UNKNOWN` for CHIP_TYPE/CHIP_INFO grabbed stray ACK frames.
- Infinite `WaitForResponse` on ACK; leftover `resp` printed as “Unknown flash
  error.”
- CoreBluetooth `writeWithoutResponse` flood (fixed in ProxBuddy outbox).
- Hadouken truecolor art OOMed the iOS app (gated off for non-TTY).

---

## Direction (locked)

Fix it in the **bootrom**, with a **shared de-framer**, and make the flash
protocol tolerate a lost frame.

Do **not**:

- Change BWM/ESP firmware to coalesce Proxmark frames.
- Stage the image to external flash and flash locally (new protocol, can’t
  safely flash bootrom, relocates risk).
- Flash bootrom from the OS (OS has no flash-write path; `CMD_FINISH_WRITE` in
  `armsrc` just resets into bootrom).

Keep BLE as the primary path for the **console** (always-on, no Local Network
prompt).

### Amendment (2026-09-17): flashing is Wi-Fi-only on this branch

Wi-Fi flashing works end to end. BLE does not, and the two share everything
below the transport, so the remaining fault is BLE-specific:

- `proxmark3` on Mac, `tcp:192.168.1.62:7777`, full `fullimage.elf`: **158/158
  blocks, "All done."** That exercises the bootrom BWM path, the shared
  de-framer, the self-locating `CMD_FINISH_WRITE`, and the ESP forwarder.
- The same bootrom over BLE from iOS still fails mid-transfer.

So this is a *scope* decision, not the "Wi-Fi-only to dodge BLE MTU" product
decision rejected above. ProxBuddy now refuses to start a flash unless libpm3
dialed `tcp:host:port` itself (`PM3Session.flashBlockedReason`). A truncated
write leaves an OS that only a computer can recover, so a link known to
truncate should not be offered at all.

BLE flashing is parked, not abandoned. To pick it back up, start at the ESP
UART0 console (GPIO19/20, 74880 baud) and find where bytes die between
`BLETransport` and `bwm_boot_pump()`.

**Bootrom over Wi-Fi is enabled.** Confirmed on hardware:

```
./client/proxmark3 tcp:192.168.1.62:7777 --flash --unlock-bootloader \
    --image armsrc/obj/fullimage.elf --image bootrom/obj/bootrom.elf -d 2
```

ProxBuddy's flash card is that same command: "Allow bootrom writes" is
`--unlock-bootloader` (default off), and the file picker takes both ELFs at
once. `check_segs()` still refuses bootloader segments when the flag is off.
The client decides what actually targets the bootloader from the ELF's PHDR
addresses (`files_target_bootloader()`); the filename check is only a clearer
error than a segment-range reject.

Wireless bootrom writes are the same RAM-resident IAP as USB (`.bootphase2` is
`>ram AT>bootphase2`). A failed write is recovered with USB + Artery ISP
(6 s button + USB pulls `BOOT0`) or SWD — not a dead board, but it needs a
computer. The toggle exists because of that recovery path, not because the
protocol is USB-only.

---

## Architecture

```
iPhone (ProxBuddy)
  BLE ATT chunks (~182 B)  ──►  ESP (BWM)
       DATA_FORWARD 8089, one ESP frame per BLE write
                                │
                                ▼
                         UART4 @ 921600
                                │
                         bootrom / OS
                    app_com de-framer + byte FIFO
                    assemble 544-byte OLD commands
```

New shared module: `common_arm/bwm/bwm_frame.[ch]`

Owns everything transport-independent:

- app_com constants (today duplicated in `armsrc/bwm_forward.h` and
  `bootrom/bwm_boot.c`)
- CRC-16/CCITT-FALSE
- RX de-framer state machine
- de-framed byte FIFO
- TX frame builder
- `SLAVE_RESP` ack accounting

Does **not** own byte-level UART I/O. OS uses a 16 KB circular-DMA ring;
bootrom polls UART4 (16-byte FIFO). Interface is feed-and-drain: caller pushes
raw UART bytes in, drains reassembled payload bytes out. No function pointers.

Compile-time FIFO sizes: ~2 KB for OS (`.bss`), small for bootrom. RAM is not
the bootrom constraint.

Stay in `armsrc/bwm_forward.c`: DMA glue, baud negotiation, flow-control window
policy. Refactor must be behaviour-preserving for the OS BLE terminal path.

### Bootrom receive model

`bwm_boot.c` becomes: poll UART → feed → drain into a **persistent 544-byte
staging buffer** that survives main-loop iterations → dispatch only when 544
bytes have accumulated.

**Idle-timeout flush is load-bearing.** OLD frames have no resync pattern. One
lost chunk leaves the bootrom permanently offset unless quiet time discards a
partial command. A few hundred milliseconds of idle, well inside the client’s
15 s retry window.

This also removes three current bugs by construction:

- `bwm_boot_write` nulling the RX dest while waiting ~50 ms for `SLAVE_RESP`
- `pump()` breaking on first packet and leaving bytes in the USART register
- no buffering during flash erase

Keep: button abort, `WDT_HIT()`, non-blocking main loop. Do not sleep 10 ms on
every iteration (overflows UART4 at 921600).

### Flash budget

Measured PM5 bootrom (current tree):

| Section        | Size    | Limit / note                          |
|----------------|---------|---------------------------------------|
| `.bootphase2`  | 14528 B | 15872 B region → **1344 B free**      |
| `.bss`         | 5056 B  | RAM; not the limiter                  |

Estimate for FIFO + staging: 150–250 B extra flash (de-framer already exists).
Measure before cutting features. `DEFCFLAGS` is already `-Werror -Os`.

---

## Phases

### 0 — Confirm fragmentation on hardware

Temporarily have the bootrom report inbound `DATA_FORWARD` lengths (existing
`#if DEBUG` / `CMD_DEBUG_PRINT_STRING` path).

Expect: three frames of ~182/182/180 per 544-byte command, not one of 544.

USB-flash that debug bootrom, then start a wireless flash far enough to see
CHIP_INFO / first `FINISH_WRITE`.

Success: lengths match the theory, or we stop and re-diagnose.

### 1 — Shared framing module + OS refactor

1. Add `common_arm/bwm/bwm_frame.[ch]`.
2. Wire `common_arm/bwm` into `Makefile.common` (`INCLUDE` + `VPATH`) and both
   CMake lists.
3. Refactor `armsrc/bwm_forward.c` onto it. Keep DMA, baud, FC window.
4. Build OS for **PM5 and RDV4**, Makefile and CMake.
5. Smoke the BLE terminal on a healthy OS image. **No regression.**

Success: OS still talks over BLE/Wi-Fi as today; one de-framer implementation.

### 2 — Bootrom on the shared module

Rewrite `bootrom/bwm_boot.c` to the feed/drain + 544-byte staging + idle flush
model. Keep `bwm_boot_init` / `poll` / `write` signatures unless bootrom.c
needs a trivial drain loop change.

Measure `.bootphase2` vs 1344 B free. If it overflows, stop and discuss before
cutting (do not silently drop USB, button abort, or `WDT_HIT`).

USB `./pm3-flash-bootrom` this image. Wireless cannot deliver a bootrom fix
while the receiver is the broken code.

Success: bootrom still USB-flashes; size in budget; wireless CHIP_* still work.

### 3 — Protocol tolerates a lost frame

Bootrom: reset the 2 KB `FINISH_WRITE` accumulator when the incoming address is
not the expected next address, so a resent block cannot desync it.

Client (`client/src/flash.c`):

- Retry `write_block` on ACK timeout, with a quiet gap so the bootrom idle
  flush fires first. Address-keyed; do not blindly continue after a NACK.
- Keep the chip-type / chip-info fixes: do not store `0` as AT91 on timeout;
  unknown AT32 id → 1024 K with a warning; wait for the exact cmd; ELF `PM5V`
  magic as fallback.
- Keep ACK timeout (no infinite wait); do not decode leftover `resp` as a
  flash-chip error.
- Add a `DEVICE_INFO` capability bit for a stream-capable forward path. Client
  says “this bootloader predates wireless flashing, update it over USB”
  instead of an 8 s hang.

Success: a dropped ATT write during block N retries block N; flash continues.

### 4 — Hardware end-to-end (OS image)

Each bootrom iteration: USB `./pm3-flash-bootrom`, then wireless `fullimage`
over BLE.

**“All done” is not success.** Earlier runs reported progress while writing
garbage. Read back at least the first and last blocks (`CMD_READ_MEM_DOWNLOAD`)
and compare to the ELF.

Then reconnect and confirm `hw version` OS matches the flashed image.

If OS is half-written: stay in bootrom and retry (do not short-press into a
dead OS). USB `./pm3-flash-fullimage` is the recovery if wireless retry fails.

Success: full 158-block image verifies; device boots the new OS over BLE.

### 5 — ProxBuddy v1

- Rebuild `libpm3client` via `./build_pm3_ios.sh`.
- Retry-aware progress (block N/M, not a frozen 0%).
- On failure: **stay in bootrom and retry** — do not nudge the user to reboot
  into a half-written OS.
- Flash is Wi-Fi-only (`flashBlockedReason`). BLE console stays.
- Bootrom writes are opt-in via the same `--unlock-bootloader` flag the Mac
  client uses. BYO `.elf`, ELF magic check.

Success: a user on Wi-Fi can pick `fullimage.elf` (and `bootrom.elf` with the
toggle on), flash, and get a working device or a clear retry path.

### 6 — Upstream PRs (Iceman)

Split. Reviewers dislike mixed ARM/host diffs.

1. **Bootrom BWM forward + shared `bwm_frame`** — ARM only, includes the
   `armsrc` refactor. Argument: this bug *is* the cost of the duplicated
   de-framer.
2. **Client flash robustness** — infinite ACK wait, 256 K default, AT91-on-
   timeout, block retry, non-TTY progress, capability bit. Frame as general
   bugs (they bite a marginal USB cable too).
3. **`pm3_flash()` public libpm3 API** — already sketched; keep it out of
   `pm3.c` so `build_pm3_ios.sh` cleanup cannot wipe it.

Per `AGENTS.md`: zero warnings gcc; also clang; `client/Makefile` +
`client/CMakeLists.txt` + `experimental_lib/CMakeLists.txt`; ARM for PM5 and
RDV4; `make check`; say which of Linux / Windows / macOS were actually run.

---

## Product notes (v1 vs later)

| Item                         | v1                         | Later                                      |
|------------------------------|----------------------------|--------------------------------------------|
| OS (`fullimage.elf`) over BLE/Wi-Fi | Yes                   | —                                          |
| Bootrom over wireless        | Gated off                  | After retry path has hardware miles        |
| BWM/ESP OTA                  | Out of scope               | Separate                                  |
| Hosted firmware artifacts    | Out of scope               | Manifest keyed by bundled client version   |

Wireless bootrom is not “impossible.” It is the same RAM-resident IAP as USB.
Recovery if it fails is ISP/SWD (needs a computer), not wireless. Warn in UI
copy; do not ship the button until retries are proven.

Dev loop while *we* are breaking `bwm_boot.c`: every bootrom iteration is USB
first. That is only because the receiver is the code under edit.

---

## Chicken-egg (users with old bootrom)

A BWM-capable, stream-capable bootrom must go on **once over USB**. After that,
OS updates are wireless. The capability bit is how the app explains this
instead of hanging.

---

## Testing checklist

- [ ] Phase 0: inbound `DATA_FORWARD` lengths logged
- [ ] OS BLE terminal unchanged after `bwm_frame` refactor (PM5)
- [ ] Bootrom `.bootphase2` still fits (record size in the PR)
- [ ] USB `pm3-flash-bootrom` still works (regression)
- [ ] Wireless flash: range `0x08004000–0x08100000`, AT32 id `0x70083347` (RGT7)
- [ ] Block 0 ACK received; progress through 158 blocks
- [ ] Read-back first/last blocks match ELF
- [ ] Forced drop / retry: kill a BLE write mid-flash, confirm retry of that
      address, image still verifies
- [ ] Failure UX: device left in bootrom; retry without short-press
- [ ] RDV4 / AT91 USB flash still works (no AT32 defaults on that path)
- [ ] gcc + clang client; Makefile + CMake + experimental_lib
- [ ] `make check`

---

## Files (expected)

| Area        | Path |
|-------------|------|
| Shared      | `common_arm/bwm/bwm_frame.c`, `bwm_frame.h` |
| Build       | `common_arm/Makefile.common`, `bootrom/Makefile`, `bootrom/CMakeLists.txt`, `armsrc/Makefile`, `armsrc/CMakeLists.txt` |
| OS          | `armsrc/bwm_forward.c`, `armsrc/bwm_forward.h` (constants move) |
| Bootrom     | `bootrom/bwm_boot.c`, `bootrom/bwm_boot.h`, `bootrom/bootrom.c` (accumulator reset, maybe capability bit) |
| Client      | `client/src/flash.c`, `flash.h`, `include/pm3_cmd.h` (new DEVICE_INFO flag) |
| ProxBuddy   | `PM3Session.swift`, `DeviceInfoView.swift`, `BinaryRunner.swift`; dylib via `build_pm3_ios.sh` |
| Unchanged   | `Proxmark5_BWM_esp32` |

---

## Open questions (only if they block)

- Exact idle-flush timeout (start ~200–300 ms; tune on hardware).
- Exact `write_block` retry count / backoff.
- Whether PR 1 lands the `armsrc` refactor in the same commit series or a
  stacked PR immediately after. Preference: same PR, ARM-only.

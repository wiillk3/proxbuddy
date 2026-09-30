# ProxBuddy 1.1 — firmware release then IPA

Ship **1.1** with Wi-Fi device flashing. Firmware ELFs go on GitHub **first** so you
can validate **Flash matching release** from a dev build; then archive and ship
the **1.1 IPA**.

The pin is the **Iceman proxmark3 commit** in both `libpm3client` and the device
ELFs. App version **1.1** is the GitHub Release tag (`v1.1`) and TestFlight build.

---

## Repos

| Repo | Path |
|------|------|
| Iceman proxmark3 (wireless flash merged, PR #3650) | `~/d3v/proxmark/proxmark3` |
| ProxBuddy | `~/d3v/proxmark/PM5/proxBuddy` |

Do **not** use the old `will/proxmark3` fork. Do **not** leave ProxBuddy-only
patches (e.g. BLE loopback in `comms.c`) edited in the Iceman tree — those live
in `proxBuddy/patches/` and are applied only by `build_pm3_ios.sh`.

---

## Order of operations

```text
1. Iceman master @ PM3_COMMIT
2. build_pm3_ios.sh + Xcode → dev build on iPhone
3. publish_firmware_release.sh --skip-ipa  →  v1.1 ELFs + manifest on GitHub
4. Device: Flash matching release (Wi-Fi)  →  validate download + flash
5. Archive ProxBuddy 1.1 IPA  →  attach to v1.1 release (or full publish with --ipa)
```

You cannot fully validate 1.1 until step 4 works — wireless flash needs bootrom +
OS built from the same commit as the app client.

---

## Phase 1 — Pin Iceman and build the client

```bash
cd ~/d3v/proxmark/proxmark3
git fetch origin
git checkout master
git pull
PM3_COMMIT=$(git rev-parse HEAD)
echo "Pin: $PM3_COMMIT"
```

Confirm wireless flash is in the tree (optional):

```bash
git log -1 --oneline --grep='wireless-device-flashing\|BWM.*flash' || \
  test -f bootrom/bwm_boot.c && echo "bwm_boot.c present"
```

Build iOS client (ProxBuddy patches applied here only):

```bash
cd ~/d3v/proxmark/PM5/proxBuddy
./build_pm3_ios.sh ~/d3v/proxmark/proxmark3
```

Note:

```text
==> Client version: Iceman/master/v4.…-gXXXXXXXX
```

```bash
xcodegen
open ProxBuddy.xcodeproj
```

Install on **iPhone** (not Simulator). **Settings → About**:

- **App version** → `1.1`
- **pm3client** → must match the `Client version` line from the build script

---

## Phase 2 — Publish v1.1 firmware (no IPA yet)

`Info.plist` is already **1.1** — use `--ipaV 1.1` so the release tag is **`v1.1`**.

**Dry-run** (builds ELFs, prints manifest, does not upload):

```bash
cd ~/d3v/proxmark/PM5/proxBuddy

./scripts/publish_firmware_release.sh \
  --path ~/d3v/proxmark/proxmark3 \
  --commit "$PM3_COMMIT" \
  --ipaV 1.1 \
  --skip-ipa \
  --draft \
  --message $'ProxBuddy 1.1 device firmware\nPM5 fullimage + bootrom (Wi-Fi flash).\nMatches bundled pm3 client at this commit.' \
  --dry-run
```

Check output: client version matches About, ELF sizes sane, manifest JSON looks right.

**Publish firmware + manifest:**

```bash
./scripts/publish_firmware_release.sh \
  --path ~/d3v/proxmark/proxmark3 \
  --commit "$PM3_COMMIT" \
  --ipaV 1.1 \
  --skip-ipa \
  --draft \
  --message $'ProxBuddy 1.1 device firmware\nPM5 fullimage + bootrom (Wi-Fi flash).\nMatches bundled pm3 client at this commit.' \
  --commit-manifest --push \
  -y
```

This creates draft **`v1.1`** with `fullimage.elf` + `bootrom.elf` and pushes
`firmware/manifest.json` to `main`. Wait ~1 minute before testing on device.

If **`v1.1` already exists** on GitHub from a failed attempt, use `--tag v1.1.1-fw`
for a firmware-only retry or delete the draft release first.

---

## Phase 3 — Validate download + flash (dev build)

Requirements:

- PM5 connected on **Wi-Fi** (Devices → Connection → Switch to Wi-Fi)
- pm3 client running

Steps:

1. **Devices → Device Specs & Hardware Info**
2. **DEVICE FIRMWARE** should show hosted release **v1.1**
3. Leave **Allow bootrom writes** off → flash **OS only** first
4. Tap **Flash matching release**
5. **Terminal** — fetch, sha256 verify, flash progress, `[+] flash finished`
6. **hw version** — new OS build

Second pass (optional): enable **Allow bootrom writes**, flash again (OS + bootrom).
Failed bootrom write → recover over USB (Artery ISP).

If **“No GitHub release for …”**:

- About `pm3client` commit ≠ manifest → rebuild app or republish with same `$PM3_COMMIT`
- Manifest not on `main` yet → confirm `--commit-manifest --push`

---

## Phase 4 — Ship the 1.1 IPA

Only after Phase 3 passes.

1. Confirm `CFBundleShortVersionString` is **1.1** in `ProxBuddy/Info.plist`
2. **Do not** change proxmark3 commit or re-run `build_pm3_ios.sh` unless you
   intentionally bump the pin (if you do, republish firmware at the new commit)
3. Xcode → **Product → Archive** → export `.ipa`
4. Attach to the existing draft release:

```bash
gh release upload v1.1 ./ProxBuddy.ipa --repo wiillk3/proxbuddy
```

5. Publish when ready:

```bash
gh release edit v1.1 --repo wiillk3/proxbuddy --draft=false
```

---

## Phase 5 — Optional: one-shot publish with IPA check

If you prefer the script to verify IPA dylib matches firmware before upload:

```bash
./scripts/publish_firmware_release.sh \
  --path ~/d3v/proxmark/proxmark3 \
  --commit "$PM3_COMMIT" \
  --ipaV 1.1 \
  --ipa ~/Desktop/ProxBuddy.ipa \
  --message $'ProxBuddy 1.1 — Wi-Fi firmware flash' \
  --commit-manifest --push \
  -y
```

Only works if **`v1.1` does not already exist**. If you already published firmware
in Phase 2, use **Phase 4** (`gh release upload`) instead.

---

## Quick reference

| Item | Value |
|------|--------|
| App / release version | **1.1** |
| Release tag | **v1.1** |
| proxmark3 clone | `~/d3v/proxmark/proxmark3` (Iceman master) |
| Commit pin | `git rev-parse HEAD` at build + publish time |
| Manifest URL | `https://raw.githubusercontent.com/wiillk3/proxbuddy/main/firmware/manifest.json` |
| Flash in app | Device Specs → **Flash matching release** (Wi-Fi only) |
| IPA for flashing | Not used — only ELFs + manifest |

---

## Do not

- Edit Iceman `comms.c` (or other client files) by hand for ProxBuddy — use patches
- Publish firmware from a different commit than the dylib in the 1.1 IPA
- Flash over BLE only — Wi-Fi TCP required
- Skip firmware publish and expect **Flash matching release** to work on stock devices

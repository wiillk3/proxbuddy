# ProxBuddy

ProxBuddy is a native iOS terminal and companion for **Proxmark5**. It embeds the RRG/Iceman `proxmark3` client (`libpm3client.dylib`) in-process and talks to the PM5 BWM over **Bluetooth LE** or **Wi-Fi** (station + TCP).

## TestFlight

Public beta: [https://testflight.apple.com/join/vwP8HPkv](https://testflight.apple.com/join/vwP8HPkv)


### Match the bundled client

The app ships a specific Iceman client build. Flash the PM5 to the same commit or commands can disagree with firmware.

1. In the app: **Settings → About**. The `pm3client` line looks like `Iceman/master/v4.21611-1177-g83c3f81b1`.
2. The `g…` suffix is the git commit (`g83c3f81b1` → `83c3f81b1`).
3. In your [Iceman proxmark3](https://github.com/RfidResearchGroup/proxmark3) clone:

```bash
git fetch
git checkout 83c3f81b1   # hash from About, without the leading g
```

Then build and flash the PM5 the usual Iceman way.

## Key Features

- **Native terminal** — full pm3 client on device: history, ANSI color, auto-scroll.
- **Command builder** — browse commands and options, then send the generated line to the terminal.
- **Dump manager** — picks up `.bin` / `.json` / `.eml` dumps, shows sector keys and blocks, and can load or write them back through the client.
- **PM5 radio** — BLE SPP to the BWM, or TCP to the BWM Wi-Fi server (`hw bwmwifi`, default port 7777). Scan and connect from the Devices tab.
- **Scripts** — Lua and Python from the Iceman tree run on device (Python 3.13 via BeeWare).
- **Optional GPS tags** — off by default; can attach location sidecars to dumps.

On a **physical iPhone**, connect a PM5 over BLE or Wi-Fi. In the **iOS Simulator**, plug a USB Proxmark into the Mac instead (see Build and run).

## Prerequisites

- macOS with **Xcode 26+**
- **Homebrew**
- **XcodeGen**
- A clone of **[RRG/Iceman proxmark3](https://github.com/RfidResearchGroup/proxmark3)** (used only to compile the iOS client)
- An iPhone and a Proxmark5 (device), or a USB Proxmark on the Mac (Simulator)

Do not put GNU `ar` ahead of Apple’s on `PATH` (Homebrew `binutils` is the usual culprit). The iOS build must archive with Xcode’s `ar`.

## Getting Started

Build steps have been tested on one machine besides the author’s. Please report errors.

### 1. Compile the iOS client and bundle scripts

```bash
git clone https://github.com/RfidResearchGroup/proxmark3.git ~/proxmark3 # if needed
./build_pm3_ios.sh ~/proxmark3 # existing clone is fine
```

You must pass the Iceman path. The script:

- Cross-compiles `libpm3client.dylib` for iOS arm64
- Downloads BeeWare’s Python 3.13 XCFramework (stdlib is copied into the app at Xcode build time)
- Copies Iceman `lua` / `py` / `cmd` scripts, dictionaries, and hardnested tables (`pm3-resources/`) into `ProxBuddy/Resources`
- Cross-compiles the nested/DES helper tools into `ProxBuddy/Resources/tools` (those `.dylib`s are build outputs, not git)

If the link step fails with `archive member '//' not a mach-o file` in `libcrypto.a`:

```bash
brew unlink binutils   # if installed
./build_pm3_ios.sh --clean ~/proxmark3
```

### 2. Generate the Xcode project

```bash
brew install xcodegen   # if needed
xcodegen
```

Run step 1 **before** `xcodegen` on a fresh clone. The project file is generated and not committed.

After that, re-run only what changed:

- Iceman client, scripts, or Python bundle — `./build_pm3_ios.sh ~/proxmark3` (add `--update-pm3-git` to pull upstream first)
- `project.yml` — `xcodegen`

If Xcode’s **Install Python stdlib** phase fails with `rsync` / `(l)stat` / `ios-arm64/lib`, pull, run `xcodegen` again, and rebuild.

### 3. Build and run

Open `ProxBuddy.xcodeproj` in Xcode and set your Team under Signing & Capabilities.

- **Physical iPhone** — the app `dlopen`s `libpm3client.dylib` on a background thread. BLE relays the client UART to the PM5 SPP characteristic. Wi-Fi opens `tcp:host:port` the same way desktop `pm3 -p tcp:…` does (bring the BWM up first with `hw bwmwifi` over BLE or USB). Pick **PM5 BLE** or **Wi-Fi** on the Devices tab, then connect.
- **iOS Simulator** — plug a USB Proxmark into the Mac (RDV4 and PM5 tested; PM3 Easy should work). If the host `proxmark3` is not at `~/proxmark3`, Homebrew, or `/usr/local/bin`, set `SimulatorBoot.clientPath` in `ProxBuddy/Runner/SimulatorBoot.swift`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: branch off `main`, open a PR.

## License

Copyright (C) 2026 ProxBuddy Project & Contributors.

ProxBuddy is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) and [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md). Privacy policy: [PRIVACY.md](PRIVACY.md).

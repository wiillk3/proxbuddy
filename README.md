# ProxBuddy

ProxBuddy is a native iOS companion app and full terminal client for the Proxmark3 (PM3). 

Built with SwiftUI, ProxBuddy embeds the actual `proxmark3` C client directly into the iOS app via a custom dynamic library (`libpm3client.dylib`). It provides a fully-featured PM3 terminal, an intuitive command builder, and a visual dump manager for organizing and manipulating card captures directly from your phone.

## Key Features

- **Full Native Terminal**: Interact with the `proxmark3` client exactly as you would on a desktop. Features command history, ANSI color support, and auto-scrolling.
- **Visual Command Builder**: Forget the exact arguments for a command? Use the interactive builder to browse commands, options, and parameters visually, then push the generated command straight to the terminal.
- **Dump Manager**: Automatically captures and organizes `.bin`, `.json`, and `.eml` dumps. View sector keys, manipulate blocks, and seamlessly load dumps back into emulator memory or write them to physical cards.
- **Hardware Integration**: Connect physical PM3 hardware directly via USB (using the Simulator path or natively when supported) and execute real hardware commands (`hf mf sim`, `hf mf autopwn`, etc.).
- **Offline / Script Mode**: The app automatically boots in an offline/script environment if no hardware is detected, allowing you to parse dumps and run scripts locally on the iOS device.

## Prerequisites

- **Xcode 15+** and macOS
- **Homebrew**
- **XcodeGen** (for generating the Xcode project file)
- **Proxmark3 RRG/Iceman source code** (required for compiling the iOS library)

## Getting Started

### 1. Compile the Proxmark3 iOS Library & Python Dependencies
ProxBuddy relies on a custom dynamic library (`libpm3client.dylib`) built from the official Proxmark3 source code, along with an embedded Python 3.11 framework.

1. Clone the official Iceman Proxmark3 repository alongside ProxBuddy:
```bash
git clone https://github.com/RfidResearchGroup/proxmark3.git ~/proxmark3
```
2. Run the build script, passing the path to the newly cloned repository:
```bash
./build_pm3_ios.sh ~/proxmark3
```
This script does the heavy lifting:
- Configures CMake for an iOS/Aarch64 target.
- Downloads BeeWare's `Python-Apple-support` framework for iOS.
- Packages the Python standard library into a highly-optimized `python311.zip` archive.
- Bundles the official Proxmark3 `lua`, `py`, and `cmd` scripts directly into the `ProxBuddy/Resources` folder.
- Compiles the client into a single `.dylib`.

### 2. Generate the Xcode Project
This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to manage the project file, which keeps the git history clean and prevents merge conflicts. 

If you don't have XcodeGen installed:
```bash
brew install xcodegen
```

Run the following command in the root of the repository to generate `ProxBuddy.xcodeproj`:
```bash
xcodegen
```
*Note: You must run the build script in Step 1 **before** running `xcodegen`, so that XcodeGen can properly link the downloaded Python framework and script directories!*

### 3. Build and Run
Open the generated `ProxBuddy.xcodeproj` in Xcode.

- **Running on iOS Simulator**: The simulator path utilizes `posix_spawn` to run the native macOS `proxmark3` executable in the background and connects to it via a Pseudo-Terminal (PTY). If you have a PM3 plugged into your Mac via USB, the simulator will detect the `/dev/tty.usbmodem` port and give you full hardware connectivity instantly.
- **Running on Physical iOS Device**: The app uses `dlopen` to load `libpm3client.dylib` into the app's process memory, creating a dedicated C-thread for the PM3 engine and routing stdin/stdout over to the SwiftUI terminal.

## Roadmap & Notes
- **Proxmark 5 Support**: Native BLE and Wi-Fi Direct to the PM5 BWM module.

## License
ProxBuddy is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) and [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

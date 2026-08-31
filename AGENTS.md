# AGENTS.md

ProxBuddy is an open-source native iOS app: a terminal and companion for the
Proxmark5. It embeds the RRG/Iceman `proxmark3` C client as `libpm3client.dylib` and
runs it **in-process** via `dlopen`, alongside an embedded CPython 3.13 runtime, and
talks to hardware over Bluetooth LE or TCP/Wi-Fi.

## Read this first: most of the tree is generated

Only about 55 files are tracked in git. Everything binary is produced by
`./build_pm3_ios.sh` and XcodeGen. **Editing a generated path wastes your work** —
the next build overwrites it. Before changing a file, check it against this table.

| Path | Produced by | Where a fix actually belongs |
|---|---|---|
| `ProxBuddy.xcodeproj/` | XcodeGen | Edit `project.yml` |
| `ProxBuddy/Resources/libpm3client.dylib` | `build_pm3_ios.sh` cross-compile | Upstream proxmark3, `patches/ios-shared-lib.patch`, `patches/ios-pm3-no-process-exit.patch`, or `patches/ios-pm3-startup-banner.patch` |
| `ProxBuddy/Resources/tools/*.dylib` | `build_pm3_ios.sh` | Upstream proxmark3, or `patches/pm3_ios_exit.c` |
| `ProxBuddy/Resources/luascripts/` | Copied from the Iceman clone | Upstream, or a patch step in `build_pm3_ios.sh` |
| `ProxBuddy/Resources/pyscripts/` | Copied from the Iceman clone | Same |
| `ProxBuddy/Resources/cmdscripts/` | Copied from the Iceman clone | Same |
| `ProxBuddy/Resources/lualibs/` | Copied from the Iceman clone | Same |
| `ProxBuddy/Resources/dictionaries/` | Copied from the Iceman clone | Same |
| `ProxBuddy/Resources/pm3-resources/` | Copied from the Iceman clone (`client/resources/`, incl. hardnested tables). Cannot be bundled as `resources/` — iOS codesign reserves that name. | Same |
| `ProxBuddy/Python.xcframework/` | Downloaded BeeWare release | Upstream BeeWare |
| `ProxBuddy/Resources/python31*.zip` | `build_pm3_ios.sh` | That script |
| `.app/python/lib/**`, `.app/Frameworks/*.framework` | `scripts/install_python_ios.sh` post-compile phase | That script |

`ProxBuddy/AI/` and `ProxBuddy/AIContexts/` are on disk for some checkouts but are
excluded from the build target by `project.yml` and gitignored. They are not part of
the shipped app; do not treat them as live code.

## Build order

`./build_pm3_ios.sh <path-to-proxmark3-clone>` must run **before** `xcodegen`. The
script produces the dylib and the resource trees that the generated project expects,
so running them out of order gives confusing failures. `README.md` has the full
sequence and the known Homebrew `binutils` conflict.

## Architecture, briefly

```
SwiftUI view
  -> TerminalEngine.sendCommand(_:)
    -> BinaryRunner.write(_:)
      -> worker Thread "pm3-libpm3" (8 MB stack), running the C client
        -> BLE mode:   the client's "serial port" is a loopback TCP socket, and
                       BLETransport relays those bytes to GATT
        -> Wi-Fi mode: the client opens tcp:host:port itself, no Swift involved

pm3 stdout -> Task.detached read loop -> AsyncStream<String>
  -> TerminalEngine -> @Published [TerminalLine] -> TerminalTableView
```

In the iOS Simulator there is no BLE, so the app `posix_spawn`s a host `proxmark3`
binary against a USB Proxmark plugged into the Mac instead.

Non-obvious constraints worth knowing before you refactor:

- The C client needs a long-lived thread with a large stack; that is a real
  requirement, not an accident.
- `HOME` is overridden to the app's Documents directory so the client's `~`-relative
  paths land inside the container.
- The CPython environment variables must be set before any UI exists, which is why
  they are in `ProxBuddyApp.init()`.

## Conventions

- Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. New code must compile without
  adding `@unchecked Sendable` or `nonisolated(unsafe)`.
- Minimum deployment target is iOS 26.0. Do not change it without being asked.
- The project is GPL-3.0 and links GPL-2.0-or-later code. Any dependency you add
  must be GPL-compatible and must be recorded in `ACKNOWLEDGEMENTS.md`.
- Hardware end-to-end checks (`./validate.sh`) need a physical Proxmark and a
  specific test card, so they cannot run everywhere. Unit tests in `ProxBuddyTests`
  need no hardware.

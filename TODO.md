# ProxBuddy TODOs

## Technical Debt & Architecture
- [ ] **Handle pm3client `exit()` calls:** Currently, the `pm3client` is loaded dynamically and its `main()` runs on a background thread in the iOS app process. If the client calls `exit()` (e.g. fatal error or user types `quit`), it terminates the entire iOS application.
  - *Fix approach:* Use `ios_system` headers or a custom header to `#define exit pthread_exit` or patch the pm3client source to gracefully return instead of calling the standard C library `exit()`.

## Features
- [ ] Add your future features here...

## Python Support
- [ ] Port/patch the remaining 6 unsupported Python scripts (`theremin.py`, `fm11rf08s_recovery.py`, `mfulc_counterfeit_recovery.py`, `ntag22x_libsuncmac.py`, `pm3_help2list.py`, `des_talk.py`) so they can run on iOS. Consider dynamically patching them in `build_pm3_ios.sh` so they stay up-to-date with upstream.

## Hardware Compatibility Note
- **PM5 Readiness:** The upcoming PM5 hardware will feature an onboard ESP32, which will provide native BLE and Wi-Fi connectivity options. This will allow the iOS app to interface directly with the device without needing the ProxBridge workaround, effectively bypassing iOS USB Serial restrictions.

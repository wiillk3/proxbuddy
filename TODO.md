# ProxBuddy TODOs
- [ ] look at ipad layout and fix if needed.

- [ ] Change where gps data is shown... bad place rn

- [ ] add Custom URL Schemes and such for Flipper app and CU gui. or maybe just share dump file. idk. someway to quickly send dumps and keys to flipper/CU apps for quick emulation. 

## Hardware
- [ ] **BLE battery (BAS 0x2A19) reports 0xFF / 255%.** The PM5 BWM advertises the standard Battery Service but the level characteristic is unknown, so the UI falls back to `hw status` → Battery SoC from the BQ27427 gauge. Fix the BWM/BAS path so the device card and connection UI get a live 0–100 reading over BLE without running `hw status`.

## Client / process
- [x] **pm3client `exit()` kills the whole iOS app.** `quit` / `exit` now end the
  in-process session (`PM3_SQUIT`) without terminating ProxBuddy. Remaining libc
  `exit()` in the client and helper tools is intercepted by `pm3_ios_exit`
  (`patches/ios-pm3-no-process-exit.patch`). Rebuild with `./build_pm3_ios.sh` for
  the interceptor to land in the dylib.

## Python
- [ ] Port or patch the remaining scripts that still fail on iOS (`theremin.py`, `fm11rf08s_recovery.py`, `mfulc_counterfeit_recovery.py`, `ntag22x_libsuncmac.py`, `pm3_help2list.py`, `des_talk.py`). Prefer a `build_pm3_ios.sh` patch so they track upstream.

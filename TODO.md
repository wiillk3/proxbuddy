# ProxBuddy TODOs
- [ ] look at ipad layout and fix if needed.

- [ ] Change where gps data is shown... bad place rn

- [ ] add Custom URL Schemes and such for Flipper app and CU gui. or maybe just share dump file. idk. someway to quickly send dumps and keys to flipper/CU apps for quick emulation. 

- [ ] make a logo.

- [ ] text input still lags in some areas. I've noticed it in terminal view and command builder again (toggles included)...

## Hardware
- [ ] **BLE battery (BAS 0x2A19) reports 0xFF / 255%.** The PM5 BWM advertises the standard Battery Service but the level characteristic is unknown, so the UI falls back to `hw status` → Battery SoC from the BQ27427 gauge. Fix the BWM/BAS path so the device card and connection UI get a live 0–100 reading over BLE without running `hw status`.

## Client / process
- [x] **pm3client `exit()` kills the whole iOS app.** `quit` / `exit` now end the
  in-process session (`PM3_SQUIT`) without terminating ProxBuddy. Remaining libc
  `exit()` in the client and helper tools is intercepted by `pm3_ios_exit`
  (`patches/ios-pm3-no-process-exit.patch`). Rebuild with `./build_pm3_ios.sh` for
  the interceptor to land in the dylib.

## Python
iOS CPython (BeeWare) has no `_posixsubprocess`, `_multiprocessing`, `cryptography`, `numpy`, or `pyaudio`. Checked the current Iceman `pyscripts/` plus the bundled copies after `build_pm3_ios.sh`.

Still broken:
- [ ] **`fm11rf08s_recovery.py` / `fm11rf08s_full.py`** — they `subprocess.run` the `staticnested_*` tools. Those are already built as dylibs, but `pm3_resources_ios.py` is not in git (`pyscripts/` is gitignored) and `build_pm3_ios.sh` looks for the shim *after* overwriting that folder, so the inject never lands. Keep the shim in `patches/` and copy it in after the Iceman tree.
- [ ] **`mfulc_counterfeit_recovery.py`** — same tool-dylib path (`mfulc_des_brute`). Also uses `subprocess.Popen`, so patching only `subprocess.run` is not enough.
- [ ] **`ntag22x_libsuncmac.py` / `ntag22x_suncmac_recovery.py`** — needs pip `cryptography` (AES-CMAC) and `multiprocessing.Process`.
- [ ] **`theremin.py`** — `numpy` + `pyaudio`. Not an iOS port without rewriting audio. Low priority.

Dropped from the old list:
- `pm3_help2list.py` — gone upstream (tab completion is built at runtime now).
- `des_talk.py` — `script run` hits `import pm3` and never uses subprocess. Same pattern as `dc34.py`.

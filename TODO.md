# ProxBuddy TODOs

## Hardware
- [ ] **BLE battery (BAS 0x2A19) reports 0xFF / 255%.** The PM5 BWM advertises the standard Battery Service but the level characteristic is unknown, so the UI falls back to `hw status` → Battery SoC from the BQ27427 gauge. Fix the BWM/BAS path so the device card and connection UI get a live 0–100 reading over BLE without running `hw status`.

## Client / process
- [ ] **pm3client `exit()` kills the whole iOS app.** `libpm3client` `main()` runs on a background thread; `quit`, fatal errors, or `exit()` tear down the process. Patch the client to return instead of calling libc `exit()`, or intercept with `pthread_exit`.

- [ ] Gps logging is SPAMMING after a card dump.

## Python
- [ ] Port or patch the remaining scripts that still fail on iOS (`theremin.py`, `fm11rf08s_recovery.py`, `mfulc_counterfeit_recovery.py`, `ntag22x_libsuncmac.py`, `pm3_help2list.py`, `des_talk.py`). Prefer a `build_pm3_ios.sh` patch so they track upstream.

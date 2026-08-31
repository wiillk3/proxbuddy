# Open Source Licenses & Acknowledgements

**ProxBuddy** is an open-source iOS client built to interface with Proxmark3 and Proxmark5 RFID analysis hardware. ProxBuddy is released under the **GNU General Public License v3.0 (GPL-3.0)**.

We extend our deepest gratitude to the open-source projects, maintainers, and hardware designers who made this project possible.

---

## 1. Proxmark3 & Iceman Firmware (`libpm3client.dylib`)

* **Project**: Proxmark3 / RRG Iceman Firmware & Client
* **Upstream Repository**: [https://github.com/RfidResearchGroup/proxmark3](https://github.com/RfidResearchGroup/proxmark3)
* **Original Creator**: Jonathan Westhues
* **Maintainers & Key Contributors**: @iceman1001, @xianglin1998, and many others. The Iceman/RRG repo is the work of a long line of people — this list is nowhere near complete.
* **License**: **GNU General Public License v2.0 or later (GPL-2.0-or-later)**
* **Usage in ProxBuddy**: `libpm3client.dylib` is cross-compiled for iOS arm64 / x86_64 simulator and bundled directly into ProxBuddy to provide full native client execution and RFID command processing.

---

## 2. Proxmark5 BWM Firmware (`Proxmark5_BWM_esp32`)

* **Project**: Proxmark5 BLE/Wi-Fi Module (BWM) ESP32-C2 Firmware
* **Upstream Repository**: [https://github.com/RfidResearchGroup/Proxmark5_BWM_esp32](https://github.com/RfidResearchGroup/Proxmark5_BWM_esp32)
* **Thanks**: @nieldk and @doegox for getting BLE and Wi-Fi up on the Proxmark5, and to everyone else in that repo whose work over the years got the PM5 here. Named names are a handful of people, not the whole story.
* **License**: **GPL-3.0 / Apache-2.0 (ESP-IDF)**
* **Usage in ProxBuddy**: Wireless Bluetooth LE SPP (`0xAE86` / `0xAE88`), Battery Service (`0x180F`), and BWM Wi-Fi station + TCP server (`hw bwmwifi`, default port 7777).

---

## 3. OpenSSL Library

* **Project**: OpenSSL Cryptographic Toolkit (v3.4.1)
* **Upstream Repository**: [https://github.com/openssl/openssl](https://github.com/openssl/openssl)
* **Authors**: The OpenSSL Project Authors
* **License**: **Apache License 2.0**
* **Usage in ProxBuddy**: Cross-compiled helper libraries (`libstaticnested_*.dylib`, `libmfulc_des_brute.dylib`) for MIFARE Classic nested attacks and DES brute-forcing.

---

## 4. Python for iOS (BeeWare Project)

* **Project**: Python 3.13 Runtime for iOS
* **Upstream Repository**: [https://github.com/beeware/briefcase](https://github.com/beeware/briefcase)
* **Authors**: Python Software Foundation & The BeeWare Project
* **License**: **Python Software Foundation License (PSF) & BSD 3-Clause License**
* **Usage in ProxBuddy**: Provides in-process Python script execution for Proxmark3 python extension scripts.

---

## 5. ProxBuddy iOS Application

* **Project**: ProxBuddy
* **Repository**: [https://github.com/spot-rfid/proxbuddy](https://github.com/spot-rfid/proxbuddy)
* **License**: **GNU General Public License v3.0 (GPL-3.0)**

---

### License Summaries & Compliance

- **Copyleft Compliance**: Because ProxBuddy links against GPL-licensed components (`libpm3client`), ProxBuddy is distributed under the GPL-3.0 license.
- **Source Availability**: The complete source code of ProxBuddy and the build scripts (`build_pm3_ios.sh`) are made freely available to ensure full compliance with GPL copyleft requirements.

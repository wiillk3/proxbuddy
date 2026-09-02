# ProxBuddy Privacy Policy

Last updated: 1 September 2026

ProxBuddy is an unofficial companion for Proxmark hardware you own. It does not require an account and does not include analytics, advertising, or crash-reporting SDKs.

## Data that stays on your device

The app stores the following only in the iOS app container (UserDefaults and the Documents folder):

- Terminal command history, favorites, display preferences, and the last Wi-Fi host/port you typed
- Card dumps, logs, and (if you turn it on) optional location sidecar files next to dumps

None of that is uploaded to us or to a ProxBuddy server. There is no ProxBuddy backend.

## Bluetooth and local network

Bluetooth and local-network access are used only to find and talk to your Proxmark over BLE or Wi-Fi. The app does not use those permissions to track you or to scan for unrelated devices.

## Location

Location is **off by default**. If you enable **Tag Dumps with Location** in Settings, ProxBuddy stores GPS coordinates and a reverse-geocoded place name next to dumps you save. That metadata stays on the device.

- Turn the setting off to stop collecting location
- Delete a dump (or its `.location` sidecar) in the Files tab to remove that dump’s location
- Deleting the app removes all on-device data, including location sidecars

## Third parties

We do not sell or share personal data. Commands you send over BLE or Wi-Fi go to the Proxmark you connected, not to us.

## Retention and deletion

Logs follow the retention setting in Settings (default 30 days; “Forever” if you set it to 0). Purge old logs from Settings, delete dumps in the Files tab, or uninstall the app.

## Children

ProxBuddy is not directed at children.

## Contact and source

- Source: https://github.com/spot-rfid/proxbuddy
- Support / issues: https://github.com/spot-rfid/proxbuddy/issues

ProxBuddy is licensed under the GNU General Public License v3.0. The program is provided without warranty.

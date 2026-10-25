# Manoto VPN

Professional Flutter Android VPN client starter for VLESS and Trojan.

## Features
- English UI
- Dark / Light mode
- Green Connected / white Disconnected visual language
- Default server catalog
- Ping-based server ordering
- QR import and clipboard import
- Local custom-server storage
- Hidden raw configuration from the server list UI
- Connection-state animation placeholder for the solidarity/fist icon

## Important
This repository is a clean application starter. The actual Android VPN tunnel depends on the bundled Xray runtime exposed by the selected Flutter package and must be validated on a real Android device before release.

## Build
1. Install Flutter stable.
2. Run `flutter pub get`.
3. Run `flutter build apk --release`.
4. Test VPN permission, VLESS/Trojan connectivity, DNS, reconnect, and background behavior on a physical Android device.

## Default servers
The supplied VLESS/Trojan entries are stored in `assets/configs/default_servers.json`. They are not displayed as raw URIs in the UI.

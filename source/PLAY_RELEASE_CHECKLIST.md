# Manoto VPN — Google Play release checklist

## What is included

- `app-release-review.aab`: release build for review; the current sandbox build uses the debug fallback because no private upload key was provided.
- `apk/`: split APKs for `arm64-v8a`, `armeabi-v7a`, and `x86_64`. These are much smaller than the universal APK.
- `symbols/` and `mapping/`: keep these private and upload them to Play Console when requested for crash de-obfuscation.
- `source/`: Flutter source and Android project.

## Before uploading to Play

1. Choose a final, unique `applicationId` in `android/app/build.gradle.kts`. The current starter ID is `com.manotovpn.app`; changing it after the first Play release is not possible.
2. Create an upload key on a secure machine:

   ```bash
   keytool -genkeypair -v -keystore manoto-vpn-upload-key.jks \
     -keyalg RSA -keysize 4096 -validity 10000 -alias upload
   ```

3. Copy `android/key.properties.example` to `android/key.properties`, fill in the passwords and absolute keystore path, and keep both files private.
4. Run `scripts/build_play_release.sh` from the Flutter project root. Upload the resulting `build/app/outputs/bundle/release/app-release.aab`.
5. Never upload the universal APK to Play when split APKs or an AAB are available. Google Play will generate device-specific APKs from the AAB.
6. In Play Console complete the App content declarations: privacy policy, Data safety, Ads declaration, App access, target audience, content rating, and VPN permission disclosure.
7. Provide a public privacy-policy URL that matches actual logging, endpoint behavior, SDKs, and analytics. The included privacy policy is a template only.
8. Test on physical Android devices: VPN permission, connect/disconnect, reconnect, DNS behavior, background/lock screen, IPv4/IPv6, VLESS/Trojan endpoints, QR import, clipboard import, and configuration deletion.
9. Upload the exact matching `mapping.txt` and native debug symbols for the uploaded build. Do not mix symbols between builds.

## Size notes

The old universal APK bundled all native libraries and was about 90 MB. The split APKs in this package are about 37–39 MB each because each contains only one CPU architecture. The AAB is the correct Play artifact; Play serves only the required native libraries to each device.

The large remaining assets are the Xray runtime and `geoip.dat`/`geosite.dat`, which are required by the current VPN package. Removing them would change or break routing behavior.

## Important limitation

This project is a functional test build, not a guarantee of Play approval. VPN apps are subject to Google Play's VPN Service policy and must use `VpnService` only for permitted core functionality. Review the current policy and complete the declarations before submission.

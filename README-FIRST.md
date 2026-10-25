# Manoto VPN — Google Play release package

## Quick files

- `artifacts/app-release-review.aab` — AAB built with release optimizations and obfuscation. It is a review artifact; because no private upload key was supplied, the sandbox used the debug fallback. Do not upload this exact file to Play.
- `artifacts/apk/` — smaller ABI-specific APKs for device testing: arm64-v8a, armeabi-v7a, and x86_64.
- `source/` — complete Flutter/Android source, build scripts, privacy-policy template, and Play checklist.
- `artifacts/mapping/` and `artifacts/symbols/` — keep with the exact build for crash de-obfuscation.

## To produce the real Play-upload AAB

1. In `source/`, choose the final unique `applicationId` in `android/app/build.gradle.kts` before the first publication.
2. Run `scripts/generate_upload_key.sh` on a secure machine and back up the generated `.jks` privately.
3. Copy `android/key.properties.example` to `android/key.properties`, set the absolute keystore path and passwords, then run `scripts/build_play_release.sh`.
4. Upload `build/app/outputs/bundle/release/app-release.aab` to Play Console. Upload matching mapping/native symbols when Play requests them.
5. Complete the VPN Service declaration, Data safety, privacy policy, content rating, target audience, and store listing assets.

## Size

The previous universal APK was about 90 MB because it bundled all CPU architectures. The ABI-specific APKs here are about 37–39 MB each. Google Play uses the AAB to deliver only the required architecture to each device.

## Important

This package does not include a private signing key, real public privacy-policy URL, store screenshots, or a guarantee of Play approval. Those must be owned and supplied by the publisher. Test the VPN on physical devices and ensure the endpoint logging/privacy behavior matches the declarations.

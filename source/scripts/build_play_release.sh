#!/usr/bin/env bash
set -euo pipefail

# Run from the Flutter project root after configuring android/key.properties.
# Google Play upload: AAB. Direct device testing: split APKs.

if [[ ! -f android/key.properties ]]; then
  echo "Missing android/key.properties. Copy android/key.properties.example and configure your private upload key." >&2
  exit 1
fi

flutter pub get
rm -rf build/symbols
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
flutter build apk --split-per-abi --release --obfuscate --split-debug-info=build/symbols

echo
echo "Google Play bundle: build/app/outputs/bundle/release/app-release.aab"
echo "Device APKs:"
ls -lh build/app/outputs/flutter-apk/app-*-release.apk

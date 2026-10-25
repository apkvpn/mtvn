#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-$PWD/manoto-vpn-upload-key.jks}"
ALIAS="${2:-upload}"

if [[ -e "$OUT" ]]; then
  echo "Refusing to overwrite existing keystore: $OUT" >&2
  exit 1
fi

read -r -s -p "New keystore password: " STORE_PASSWORD
printf '\n'
read -r -s -p "New key password (use the same if unsure): " KEY_PASSWORD
printf '\n'

keytool -genkeypair -v \
  -keystore "$OUT" \
  -storepass "$STORE_PASSWORD" \
  -keypass "$KEY_PASSWORD" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Manoto VPN, OU=Mobile, O=Manoto VPN, L=Unknown, ST=Unknown, C=US"

echo "Created $OUT. Back it up privately; loss of the upload key can block updates."
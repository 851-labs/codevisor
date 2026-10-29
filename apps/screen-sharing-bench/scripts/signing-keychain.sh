#!/usr/bin/env bash
set -euo pipefail

action=${1:-}
keychain="$RUNNER_TEMP/codevisor-bench-signing.keychain-db"
original="$RUNNER_TEMP/codevisor-bench-original-keychains.txt"

import_identity() {
  : "${APPLE_CERTIFICATE_BASE64:?the Developer ID certificate secret is required}"
  : "${APPLE_CERTIFICATE_PASSWORD:?the Developer ID certificate password secret is required}"
  local certificate="$RUNNER_TEMP/codevisor-bench-certificate.p12"
  local password="$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  security list-keychains -d user >"$original"
  echo "$APPLE_CERTIFICATE_BASE64" | base64 --decode >"$certificate"
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  security import "$certificate" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain" >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" $(tr -d '"' <"$original")
  rm -f "$certificate"
}

remove_identity() {
  if [[ -f "$original" ]]; then security list-keychains -d user -s $(tr -d '"' <"$original") || true; fi
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -f "$original" "$RUNNER_TEMP/codevisor-bench-certificate.p12"
}

case "$action" in
  import) import_identity ;;
  remove) remove_identity ;;
  *) echo "Usage: $0 import|remove" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/notarize-macos-app.sh <artifact-dir>

Notarizes and staples the signed artifacts build-macos-app.sh wrote to
<artifact-dir>, rewriting them in place:
  Codevisor-arm64.dmg         stapled disk image
  Codevisor-macOS-arm64.zip   re-zipped around the stapled app

One submission covers both: notarizing the DMG also issues a ticket for the
app inside it, which is the same signed app the ZIP holds.

Required environment (App Store Connect API key):
  APP_STORE_CONNECT_API_KEY_BASE64, APP_STORE_CONNECT_API_KEY_ID,
  APP_STORE_CONNECT_ISSUER_ID
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
artifact_dir="${1:-}"
if [[ -z "$artifact_dir" ]]; then
  usage
  exit 1
fi
: "${APP_STORE_CONNECT_API_KEY_BASE64:?is required}"
: "${APP_STORE_CONNECT_API_KEY_ID:?is required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?is required}"

dmg_path="$artifact_dir/Codevisor-arm64.dmg"
zip_path="$artifact_dir/Codevisor-macOS-arm64.zip"
for artifact in "$dmg_path" "$zip_path"; do
  [[ -f "$artifact" ]] || { echo "error: missing artifact: $artifact" >&2; exit 1; }
done

started_at=$SECONDS
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codevisor-notarize.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
key_path="$work_dir/AuthKey_$APP_STORE_CONNECT_API_KEY_ID.p8"
(umask 077 && printf '%s' "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$key_path")
notary_args=(--key "$key_path" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")

ditto -x -k "$zip_path" "$work_dir"
app_path="$work_dir/Codevisor.app"
codesign --verify --deep --strict "$app_path"
codesign --verify "$dmg_path"

# `notarytool submit --wait` uploads and blocks until Apple's verdict. The
# timeout bounds a stuck Apple queue; the next scheduled publish retries.
response="$(xcrun notarytool submit "$dmg_path" "${notary_args[@]}" \
  --wait --timeout 30m --output-format json)" || true
submission_id="$(jq -r '.id // empty' <<<"$response" 2>/dev/null || true)"
status="$(jq -r '.status // empty' <<<"$response" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
  echo "error: notarization finished with status '${status:-unknown}' (submission ${submission_id:-none})" >&2
  printf '%s\n' "$response" >&2
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
  fi
  exit 1
fi
echo "Notarization accepted ($submission_id)"

# Stapling fetches the ticket from Apple's CDN, which can lag a fresh verdict
# by a minute or two (stapler error 68). That delay is the only thing retried.
staple() {
  local target="$1" attempt
  for attempt in 1 2 3 4 5; do
    xcrun stapler staple "$target" && return 0
    echo "Ticket for $(basename "$target") not on Apple's CDN yet (attempt $attempt); waiting 30s" >&2
    sleep 30
  done
  echo "error: could not staple $(basename "$target")" >&2
  return 1
}
staple "$dmg_path"
staple "$app_path"
xcrun stapler validate "$dmg_path"
xcrun stapler validate "$app_path"

rm -f "$zip_path"
ditto --norsrc -c -k --keepParent "$app_path" "$zip_path"
for artifact in "$dmg_path" "$zip_path"; do
  shasum -a 256 "$artifact" | awk '{print $1}' > "$artifact.sha256"
done
echo "Notarized and stapled in $((SECONDS - started_at))s"

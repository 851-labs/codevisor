#!/bin/sh
# The one place iroh-relay's config is written (docs/plans/codevisor-tunnel.md).
# Production (entrypoint.sh on Fly), CI smoke tests and `bun run dev`
# (scripts/dev-net.mjs) all run it; only the environment differs.
#
# Required: RELAY_HOSTNAME, RELAY_CERT_PATH, RELAY_KEY_PATH,
#           RELAY_AUTHORIZE_URL, RELAY_AUTHORIZE_TOKEN
# Optional: RELAY_HTTP_BIND_ADDR, RELAY_HTTPS_BIND_ADDR, RELAY_QUIC_BIND_ADDR,
#           RELAY_METRICS_BIND_ADDR
#
# Keys checked against the pinned iroh-relay (v1.2.0 iroh-relay/src/main.rs).
set -eu
cat <<TOML
enable_relay = true
http_bind_addr = "${RELAY_HTTP_BIND_ADDR:-127.0.0.1:8080}"
enable_quic_addr_discovery = true
enable_metrics = true
metrics_bind_addr = "${RELAY_METRICS_BIND_ADDR:-[::]:9090}"

[tls]
hostname = "$RELAY_HOSTNAME"
https_bind_addr = "${RELAY_HTTPS_BIND_ADDR:-[::]:443}"
quic_bind_addr = "${RELAY_QUIC_BIND_ADDR:-[::]:7842}"
# Reloading re-reads the files every 24 h, so certbot renewals (and dev CA
# rotations) apply without a restart.
cert_mode = "Reloading"
manual_cert_path = "$RELAY_CERT_PATH"
manual_key_path = "$RELAY_KEY_PATH"

[access.http]
url = "$RELAY_AUTHORIZE_URL"
bearer_token = "$RELAY_AUTHORIZE_TOKEN"
TOML

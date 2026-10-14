#!/bin/sh
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

#!/bin/sh
set -eu

if [ -n "${FLY_APP_NAME:-}" ]; then
  ip=$(getent ahostsv4 fly-global-services | awk 'NR==1 { print $1 }')
  export RELAY_QUIC_BIND_ADDR="$ip:7842"
fi

export RELAY_HTTP_BIND_ADDR="127.0.0.1:8080"
python3 /app/port80-router.py &

if [ -z "${RELAY_CERT_PATH:-}" ]; then
  certbot_args="--config-dir /data/letsencrypt --work-dir /tmp/le-work --logs-dir /tmp/le-logs"
  webroot=/data/acme-webroot
  live="/data/letsencrypt/live/$RELAY_HOSTNAME"
  mkdir -p "$webroot"
  attempt=0
  until [ -f "$live/fullchain.pem" ]; do
    attempt=$((attempt + 1))
    certbot certonly $certbot_args --non-interactive --agree-tos \
      -m ops@codevisor.dev -d "$RELAY_HOSTNAME" --webroot -w "$webroot" && continue
    delay=60
    [ "$attempt" -ge 4 ] && delay=900
    echo "certbot attempt $attempt failed; retrying in ${delay}s" >&2
    sleep "$delay"
  done
  ( while true; do
      sleep 43200
      certbot renew $certbot_args --quiet || echo "certbot renew failed" >&2
    done ) &
  export RELAY_CERT_PATH="$live/fullchain.pem" RELAY_KEY_PATH="$live/privkey.pem"
fi

/app/render-config.sh > /tmp/iroh-relay.toml
exec iroh-relay --config-path /tmp/iroh-relay.toml

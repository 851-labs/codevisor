#!/bin/sh
# Relay container entrypoint (Fly and CI smoke tests). Local development runs
# the same render-config.sh and port80-router.py from scripts/dev-net.mjs.
set -eu

# Fly delivers UDP only to sockets bound to fly-global-services, and
# iroh-relay's QUIC bind takes an IP. Elsewhere QUIC binds like HTTPS.
if [ -n "${FLY_APP_NAME:-}" ]; then
  ip=$(getent ahostsv4 fly-global-services | awk 'NR==1 { print $1 }')
  export RELAY_QUIC_BIND_ADDR="$ip:7842"
fi

# The port-80 router always runs: it serves HTTP-01 challenges and forwards
# everything else (captive-portal checks) to the relay's own HTTP listener.
export RELAY_HTTP_BIND_ADDR="127.0.0.1:8080"
python3 /app/port80-router.py &

# Certificates: HTTP-01 through the router, stored on the volume. CI smoke
# tests set RELAY_CERT_PATH/RELAY_KEY_PATH to a throwaway CA instead.
if [ -z "${RELAY_CERT_PATH:-}" ]; then
  certbot_args="--config-dir /data/letsencrypt --work-dir /tmp/le-work --logs-dir /tmp/le-logs"
  webroot=/data/acme-webroot
  live="/data/letsencrypt/live/$RELAY_HOSTNAME"
  mkdir -p "$webroot"
  # First boot only (the volume keeps it afterwards). A fresh relay's DNS
  # and proxy routes can take a minute to settle, so the first 4 attempts
  # retry every minute, then every 15 min: under Let's Encrypt's limit of 5
  # failed validations per hostname per hour.
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
  # Renewal loop: certbot renews within 30 days of expiry; the relay's
  # Reloading resolver picks the new files up within 24 h, no restart.
  ( while true; do
      sleep 43200
      certbot renew $certbot_args --quiet || echo "certbot renew failed" >&2
    done ) &
  export RELAY_CERT_PATH="$live/fullchain.pem" RELAY_KEY_PATH="$live/privkey.pem"
fi

/app/render-config.sh > /tmp/iroh-relay.toml
exec iroh-relay --config-path /tmp/iroh-relay.toml

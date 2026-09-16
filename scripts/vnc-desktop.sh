#!/usr/bin/env bash
# Gives a Linux machine running codevisor-server a desktop the Codevisor app
# can view as a Screen Sharing pane (docs/plans/screen-sharing-vps.md).
#
#   scripts/vnc-desktop.sh root@HOST            # idempotent
#   DISPLAY_NAME="Studio" scripts/vnc-desktop.sh root@HOST
#
# TigerVNC (Xfce) listens on localhost only, with no VNC password: nothing but
# codevisor-server on the same box reaches it, and the server only splices
# machine-authenticated clients onto it. The server learns the display from
# ~/.codevisor/data/screen-sharing.json and is restarted to pick it up.
set -euo pipefail

target=${1:-}
[[ -n "$target" ]] || { echo "Usage: $0 user@host" >&2; exit 2; }
display=${DISPLAY_NUMBER:-1}
name=${DISPLAY_NAME:-Desktop}
geometry=${GEOMETRY:-1440x900}

ssh -o StrictHostKeyChecking=accept-new "$target" \
  "DISPLAY_NUMBER=$display DISPLAY_NAME='$name' GEOMETRY=$geometry bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
port=$((5900 + DISPLAY_NUMBER))
if ! command -v vncserver >/dev/null; then
  apt-get update -q
  apt-get install -y -q tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal dbus-x11 xclip >/dev/null
fi
mkdir -p ~/.vnc
cat > ~/.vnc/xstartup <<'XS'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XS
chmod +x ~/.vnc/xstartup
cat > /etc/systemd/system/vncserver@.service <<UNIT
[Unit]
Description=Codevisor desktop, TigerVNC display :%i (localhost only, no VNC password)
After=network.target

[Service]
Type=forking
User=root
ExecStartPre=-/usr/bin/vncserver -kill :%i
ExecStart=/usr/bin/vncserver :%i -localhost yes -geometry $GEOMETRY -depth 24 -SecurityTypes None
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "vncserver@$DISPLAY_NUMBER" >/dev/null 2>&1
systemctl restart "vncserver@$DISPLAY_NUMBER"
sleep 2
systemctl is-active --quiet "vncserver@$DISPLAY_NUMBER" || { echo "vncserver@$DISPLAY_NUMBER failed" >&2; exit 1; }
ss -ltn | grep -q "127.0.0.1:$port " || { echo "Xvnc is not listening on localhost:$port" >&2; exit 1; }
data_dir="${CODEVISOR_DATA_DIR:-$HOME/.codevisor/data}"
mkdir -p "$data_dir"
printf '{ "vnc": { "port": %s, "name": "%s" } }\n' "$port" "$DISPLAY_NAME" > "$data_dir/screen-sharing.json"
if systemctl list-unit-files codevisor-server.service >/dev/null 2>&1; then
  systemctl restart codevisor-server
fi
echo "Desktop \"$DISPLAY_NAME\" on localhost:$port; $data_dir/screen-sharing.json written"
REMOTE

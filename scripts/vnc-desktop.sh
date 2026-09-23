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
#
# Idempotent and safe to rerun on a desktop in use: Xvnc and codevisor-server
# restart only when their configuration changed (restarting Xvnc ends the
# desktop session).
#
# Tuned for streaming (851-2322; measured with scripts/vnc-desktop-sample.sh):
# - xfwm4's compositor is off: shadows and fades only add repaints to send.
# - GEOMETRY is only the size the desktop starts at; the viewer resizes it to
#   its window (ExtendedDesktopSize/RandR, 851-2314).
# - Xvnc settings reviewed and left at their defaults: FrameRate 60 (the most
#   updates per second a viewer can use), CompareFB 2 (drop unchanged pixels,
#   adaptively), DeferUpdate 1 ms. The client picks encodings and JPEG quality.
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
# xdotool: scripts/vnc-desktop-sample.sh drives the desktop with it.
command -v xdotool >/dev/null || apt-get install -y -q xdotool >/dev/null
mkdir -p ~/.vnc
cat > ~/.vnc/xstartup <<'XS'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XS
chmod +x ~/.vnc/xstartup
unit=/etc/systemd/system/vncserver@.service
old_unit=$(cat "$unit" 2>/dev/null || true)
cat > "$unit" <<UNIT
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
if [[ "$(cat "$unit")" != "$old_unit" ]] || ! systemctl is-active --quiet "vncserver@$DISPLAY_NUMBER"; then
  systemctl restart "vncserver@$DISPLAY_NUMBER"
  sleep 2
fi
systemctl is-active --quiet "vncserver@$DISPLAY_NUMBER" || { echo "vncserver@$DISPLAY_NUMBER failed" >&2; exit 1; }
# The compositor setting lives in the session's xfconf (persisted to xfwm4.xml); wait for the session.
for _ in $(seq 1 50); do DISPLAY=":$DISPLAY_NUMBER" xfconf-query -c xfwm4 -p /general/use_compositing >/dev/null 2>&1 && break; sleep 0.2; done
DISPLAY=":$DISPLAY_NUMBER" xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false
ss -ltn | grep -q "127.0.0.1:$port " || { echo "Xvnc is not listening on localhost:$port" >&2; exit 1; }
data_dir="${CODEVISOR_DATA_DIR:-$HOME/.codevisor/data}"
mkdir -p "$data_dir"
config=$(printf '{ "vnc": { "port": %s, "name": "%s" } }' "$port" "$DISPLAY_NAME")
if [[ "$(cat "$data_dir/screen-sharing.json" 2>/dev/null)" != "$config" ]]; then
  printf '%s\n' "$config" > "$data_dir/screen-sharing.json"
  if systemctl list-unit-files codevisor-server.service >/dev/null 2>&1; then
    systemctl restart codevisor-server
  fi
fi
echo "Desktop \"$DISPLAY_NAME\" on localhost:$port; $data_dir/screen-sharing.json written"
REMOTE

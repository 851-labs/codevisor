#!/usr/bin/env bash
# Gives a Linux machine running codevisor-server a desktop the Codevisor app
# can view as a Screen Sharing pane (docs/plans/screen-sharing-vps.md).
#
#   scripts/vnc-desktop.sh root@HOST            # idempotent
#   DISPLAY_NAME="Studio" scripts/vnc-desktop.sh root@HOST
#   SCALE=2 scripts/vnc-desktop.sh root@HOST     # Xfce at 2× for a machine with Retina Remote Desktop on
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
# Tuned for streaming (851-2322; measured with apps/screen-sharing-rig/scripts/vnc-desktop-sample.sh):
# - xfwm4's compositor is off: shadows and fades only add repaints to send.
# - GEOMETRY is only the size the desktop starts at; the viewer resizes it to
#   its window (ExtendedDesktopSize/RandR, 851-2314).
# - No sign-in blacklist (-UseBlacklist=0): Xvnc listens on localhost only with no password,
#   so there is nothing to brute-force, and its only client, codevisor-server, connects from
#   127.0.0.1: a few dropped connections from there must not lock the desktop out (851-2335).
# - Xvnc settings reviewed and left at their defaults: FrameRate 60 (the most
#   updates per second a viewer can use), CompareFB 2 (drop unchanged pixels,
#   adaptively), DeferUpdate 1 ms. The client picks encodings and JPEG quality.
# - SCALE=2 (851-2330) makes Xfce draw at 2× for machines whose Retina Remote
#   Desktop setting is on (851-2315); SCALE=1, the default, sets it back. Apps
#   already open keep their scale until reopened.
#
# Desktop settings go through the session's own D-Bus (851-2330). An ssh shell
# has a different bus with its own xfconfd: settings written there land in the
# XML files but never reach the running desktop.
set -euo pipefail

target=${1:-}
[[ -n "$target" ]] || { echo "Usage: $0 user@host" >&2; exit 2; }
display=${DISPLAY_NUMBER:-1}
name=${DISPLAY_NAME:-Desktop}
scale=${SCALE:-1}
[[ "$scale" == 1 || "$scale" == 2 ]] || { echo "SCALE must be 1 or 2" >&2; exit 2; }
geometry=${GEOMETRY:-1440x900}

ssh -o StrictHostKeyChecking=accept-new "$target" \
  "DISPLAY_NUMBER=$display DISPLAY_NAME='$name' GEOMETRY=$geometry SCALE=$scale bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
port=$((5900 + DISPLAY_NUMBER))
if ! command -v vncserver >/dev/null; then
  apt-get update -q
  apt-get install -y -q tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal dbus-x11 xclip >/dev/null
fi
# xdotool: apps/screen-sharing-rig/scripts/vnc-desktop-sample.sh drives the desktop with it. Mousepad: Xfce's text
# editor, which apps/screen-sharing-rig/scripts/vnc-desktop-shortcuts.sh checks ⌘C/⌘V in (851-2335).
command -v xdotool >/dev/null || apt-get install -y -q xdotool >/dev/null
command -v mousepad >/dev/null || apt-get install -y -q mousepad >/dev/null
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
ExecStart=/usr/bin/vncserver :%i -localhost yes -geometry $GEOMETRY -depth 24 -SecurityTypes None -UseBlacklist=0
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
# Wait for the session, then talk to its xfconfd over its D-Bus (the panel's), not this shell's.
panel=""
for _ in $(seq 1 50); do panel=$(pgrep -o xfce4-panel || true); [[ -n "$panel" ]] && break; sleep 0.2; done
[[ -n "$panel" ]] || { echo "the Xfce session didn't start (no xfce4-panel)" >&2; exit 1; }
session_bus=$(tr '\0' '\n' < "/proc/$panel/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
xfconf() { DISPLAY=":$DISPLAY_NUMBER" DBUS_SESSION_BUS_ADDRESS="$session_bus" xfconf-query "$@"; }
xfconf -c xfwm4 -p /general/use_compositing -n -t bool -s false
old_scale=$(xfconf -c xsettings -p /Gdk/WindowScalingFactor 2>/dev/null || echo 1)
xfconf -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s "$SCALE"
# Window borders to match; SCALE=1 only undoes the 2× theme, never a theme the user picked.
if [[ "$SCALE" == 2 ]]; then
  xfconf -c xfwm4 -p /general/theme -n -t string -s Default-xhdpi
elif [[ "$(xfconf -c xfwm4 -p /general/theme 2>/dev/null)" == Default-xhdpi ]]; then
  xfconf -c xfwm4 -p /general/theme -n -t string -s Default
fi
# The panel follows the scale live; the desktop (icons) reads it at start, so restart it when it changed.
if [[ "$old_scale" != "$SCALE" ]]; then
  DISPLAY=":$DISPLAY_NUMBER" DBUS_SESSION_BUS_ADDRESS="$session_bus" timeout 10 xfdesktop --quit >/dev/null 2>&1 || true
  sleep 1
  DISPLAY=":$DISPLAY_NUMBER" DBUS_SESSION_BUS_ADDRESS="$session_bus" setsid xfdesktop >/dev/null 2>&1 < /dev/null &
fi
ss -ltn | grep -q "127.0.0.1:$port " || { echo "Xvnc is not listening on localhost:$port" >&2; exit 1; }
data_dir="${CODEVISOR_DATA_DIR:-$HOME/.codevisor/data}"
mkdir -p "$data_dir"
# desktop + defaultSize let codevisor-server set the desktop's scale and report its size (851-2339).
config=$(printf '{ "vnc": { "port": %s, "name": "%s", "desktop": "xfce", "defaultSize": "%s" } }' \
  "$port" "$DISPLAY_NAME" "$GEOMETRY")
if [[ "$(cat "$data_dir/screen-sharing.json" 2>/dev/null)" != "$config" ]]; then
  printf '%s\n' "$config" > "$data_dir/screen-sharing.json"
  if systemctl list-unit-files codevisor-server.service >/dev/null 2>&1; then
    systemctl restart codevisor-server
  fi
fi
echo "Desktop \"$DISPLAY_NAME\" on localhost:$port; $data_dir/screen-sharing.json written"
REMOTE

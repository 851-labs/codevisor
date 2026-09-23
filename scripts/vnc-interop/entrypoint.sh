#!/bin/sh
# Xvnc on :1 (port 5901) with VNC authentication and a solid root colour the
# interop tests assert on. GEOMETRY, PASSWORD and ROOT_COLOR come from
# scripts/vnc-interop.mjs.
set -eu
: "${GEOMETRY:=1024x768}" "${PASSWORD:=codevisor}" "${ROOT_COLOR:=#336699}"
mkdir -p /root/.vnc
printf '%s\n' "$PASSWORD" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
Xvnc :1 -geometry "$GEOMETRY" -depth 24 -rfbport 5901 -SecurityTypes VncAuth \
  -PasswordFile /root/.vnc/passwd -AlwaysShared -desktop "codevisor-interop" &
xvnc=$!
ready=0
for _ in $(seq 1 50); do
  # A desktop sets a root pointer (Xfce: left_ptr); bare X has none, and Xvnc then sends a hidden cursor.
  DISPLAY=:1 xsetroot -solid "$ROOT_COLOR" -cursor_name left_ptr 2>/dev/null && ready=1 && break
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "vnc-interop: xsetroot never succeeded" >&2; exit 1; }
echo "vnc-interop: ready"
wait "$xvnc"

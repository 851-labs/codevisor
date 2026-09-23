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
for _ in $(seq 1 50); do
  DISPLAY=:1 xsetroot -solid "$ROOT_COLOR" 2>/dev/null && break
  sleep 0.1
done
echo "vnc-interop: ready"
wait "$xvnc"

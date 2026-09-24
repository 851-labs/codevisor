#!/usr/bin/env bash
# Provisions a Linux VPS as a standard VNC server for interop testing of the
# VNC viewer (docs/plans/vnc-viewer.md), and opens the SSH tunnel to it.
#
#   apps/screen-sharing-rig/scripts/vnc-test-box.sh provision root@HOST   # idempotent: TigerVNC + Xfce, bound to localhost
#   apps/screen-sharing-rig/scripts/vnc-test-box.sh tunnel  root@HOST     # forwards 127.0.0.1:5901 -> the box's :1
#
# The box's Xvnc listens on localhost only (VNC Authentication is DES; it must
# never cross the internet in the clear). The pane connects to 127.0.0.1:5901
# through the tunnel, exactly like the rig's loopback server.
set -euo pipefail

command=${1:-}
target=${2:-}
vnc_password=${VNC_TEST_PASSWORD:-codevisor}
display=1
port=$((5900 + display))

usage() {
  echo "Usage: $0 provision|tunnel user@host" >&2
  exit 2
}

[[ -n "$command" && -n "$target" ]] || usage

case "$command" in
  provision)
    ssh -o StrictHostKeyChecking=accept-new "$target" "VNC_PASSWORD='$vnc_password' DISPLAY_NUMBER=$display bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal dbus-x11 xclip >/dev/null
# The SSH key of whoever provisions is already authorized; from here on keys only
# (the hosting panel's password reset is the recovery path). Nothing else listens publicly.
install -d /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/90-keys-only.conf
systemctl reload ssh 2>/dev/null || systemctl reload sshd
mkdir -p ~/.vnc
printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd
cat > ~/.vnc/xstartup <<'XS'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XS
chmod +x ~/.vnc/xstartup
cat > /etc/systemd/system/vncserver@.service <<'UNIT'
[Unit]
Description=TigerVNC display :%i (localhost only)
After=network.target

[Service]
Type=forking
User=root
ExecStartPre=-/usr/bin/vncserver -kill :%i
ExecStart=/usr/bin/vncserver :%i -localhost yes -geometry 1440x900 -depth 24 -SecurityTypes VncAuth
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now "vncserver@$DISPLAY_NUMBER"
sleep 2
systemctl is-active "vncserver@$DISPLAY_NUMBER"
ss -ltnp | grep ":$((5900 + DISPLAY_NUMBER))" || { echo "Xvnc is not listening" >&2; exit 1; }
echo "VNC :$DISPLAY_NUMBER ready on localhost:$((5900 + DISPLAY_NUMBER)) (password: $VNC_PASSWORD)"
REMOTE
    ;;
  tunnel)
    echo "Forwarding 127.0.0.1:$port -> $target:$port (Control-C to stop)"
    exec ssh -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$port:127.0.0.1:$port" "$target"
    ;;
  *) usage ;;
esac

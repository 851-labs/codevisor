#!/bin/sh
set -eu

DISPLAY_NUMBER=1
GEOMETRY=1440x900
TCP_PORT=$((5900 + DISPLAY_NUMBER))
APT_STATE=/codevisor-state/apt
LOG=/tmp/desktop.log
PACKAGES="tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal mousepad dbus-x11
  at-spi2-core python3-gi gir1.2-atspi-2.0 gir1.2-gtk-3.0 xclip xdotool x11-xserver-utils
  fonts-dejavu-core adwaita-icon-theme xauth iproute2"

desktop_tools_installed() {
  command -v Xvnc >/dev/null 2>&1 && command -v xauth >/dev/null 2>&1 && command -v ss >/dev/null 2>&1
}

if ! desktop_tools_installed; then
  echo "[container] installing the desktop (Xfce, TigerVNC, accessibility)"
  mkdir -p "$APT_STATE/archives/partial" "$APT_STATE/lists/partial"
  exec 8>"$APT_STATE/.lock"
  flock 8
  apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -qq \
      -o Dir::Cache::archives="$APT_STATE/archives" -o Dir::State::lists="$APT_STATE/lists" "$@"
  }
  # shellcheck disable=SC2086
  if ! { [ -e "$APT_STATE/updated" ] && apt_get install -y --no-install-recommends $PACKAGES >/dev/null; }; then
    apt_get update
    touch "$APT_STATE/updated"
    apt_get install -y --no-install-recommends $PACKAGES >/dev/null
  fi
  flock -u 8
fi

export DISPLAY=":$DISPLAY_NUMBER"
export XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
SOCKET="$XDG_RUNTIME_DIR/codevisor-desktop.sock"
export XAUTHORITY="$XDG_RUNTIME_DIR/codevisor-desktop.xauth"
XVNC_PID=""
: >"$LOG"

FINISHED=0
CONFIG=""

stop_unless_finished() {
  [ "$FINISHED" = 1 ] && return
  for pid in "$XVNC_PID" "${DBUS_SESSION_BUS_PID:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -f "$SOCKET" "$XAUTHORITY" "/tmp/.X$DISPLAY_NUMBER-lock" "/tmp/.X11-unix/X$DISPLAY_NUMBER"
  [ -z "$CONFIG" ] || rm -f "$CONFIG"
}
trap stop_unless_finished EXIT

give_up() {
  echo "[container] $1" >&2
  exit 1
}

refuse_an_open_tcp_port() {
  tcp_listeners=$(ss -H -ltn "sport = :$TCP_PORT" 2>>"$LOG") ||
    give_up "couldn't check that Xvnc is off TCP port $TCP_PORT (see $LOG); not sharing it"
  [ -z "$tcp_listeners" ] ||
    give_up "TCP port $TCP_PORT is open, and Xvnc must only listen on its socket; not sharing it"
}

write_cookie() {
  cookie=$(mcookie) || return 1
  (umask 077 && xauth -q -f "$XAUTHORITY" add "$DISPLAY" . "$cookie") >>"$LOG" 2>&1 || return 1
  [ -s "$XAUTHORITY" ]
}

rm -f "/tmp/.X$DISPLAY_NUMBER-lock" "/tmp/.X11-unix/X$DISPLAY_NUMBER" "$SOCKET" "$XAUTHORITY"
write_cookie || give_up "couldn't write the desktop's X11 cookie (see $LOG)"
setsid Xvnc "$DISPLAY" -auth "$XAUTHORITY" -rfbunixpath "$SOCKET" -rfbunixmode 0600 -rfbport -1 \
  -localhost -nolisten tcp -geometry "$GEOMETRY" -depth 24 -SecurityTypes None >>"$LOG" 2>&1 </dev/null &
XVNC_PID=$!
for _ in $(seq 1 50); do
  [ -S "$SOCKET" ] && [ -S "/tmp/.X11-unix/X$DISPLAY_NUMBER" ] && break
  sleep 0.2
done
if ! [ -S "$SOCKET" ] || ! [ -S "/tmp/.X11-unix/X$DISPLAY_NUMBER" ]; then
  give_up "Xvnc didn't start (see $LOG)"
fi
refuse_an_open_tcp_port
sleep 1
refuse_an_open_tcp_port
dbus_session=$(dbus-launch --sh-syntax) || give_up "the desktop's D-Bus session didn't start"
eval "$dbus_session"
setsid startxfce4 >>"$LOG" 2>&1 </dev/null &
(
  for _ in $(seq 1 100); do
    pgrep -x xfce4-panel >/dev/null && break
    sleep 0.2
  done
  xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false
) >>"$LOG" 2>&1 &

cat >/tmp/desktop.env <<ENV
export DISPLAY='$DISPLAY'
export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
export XAUTHORITY='$XAUTHORITY'
export DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS'
ENV
data_dir=${CODEVISOR_DATA_DIR:?}
mkdir -p "$data_dir"
CONFIG="$data_dir/screen-sharing.json"
printf '{ "vnc": { "socket": "%s", "display": %s, "xauthority": "%s", "name": "Desktop", "desktop": "xfce", "defaultSize": "%s" }, "devContainerDesktop": true }\n' \
  "$SOCKET" "$DISPLAY_NUMBER" "$XAUTHORITY" "$GEOMETRY" >"$CONFIG"
echo "[container] desktop on $DISPLAY (VNC socket $SOCKET)"
FINISHED=1

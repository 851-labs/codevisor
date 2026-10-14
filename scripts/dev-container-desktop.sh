#!/bin/sh
set -eu

DISPLAY_NUMBER=1
GEOMETRY=1440x900
PORT=$((5900 + DISPLAY_NUMBER))
APT_STATE=/codevisor-state/apt
LOG=/tmp/desktop.log
PACKAGES="tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal mousepad dbus-x11
  at-spi2-core python3-gi gir1.2-atspi-2.0 gir1.2-gtk-3.0 xclip xdotool x11-xserver-utils
  fonts-dejavu-core adwaita-icon-theme"

if ! command -v Xvnc >/dev/null 2>&1; then
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
eval "$(dbus-launch --sh-syntax)"
rm -f "/tmp/.X$DISPLAY_NUMBER-lock" "/tmp/.X11-unix/X$DISPLAY_NUMBER"
setsid Xvnc "$DISPLAY" -localhost -rfbport "$PORT" -geometry "$GEOMETRY" -depth 24 \
  -SecurityTypes None -UseBlacklist=0 >"$LOG" 2>&1 </dev/null &
for _ in $(seq 1 50); do
  [ -S "/tmp/.X11-unix/X$DISPLAY_NUMBER" ] && break
  sleep 0.2
done
[ -S "/tmp/.X11-unix/X$DISPLAY_NUMBER" ] || { echo "[container] Xvnc didn't start (see $LOG)" >&2; exit 1; }
setsid startxfce4 >>"$LOG" 2>&1 </dev/null &
(
  for _ in $(seq 1 100); do
    pgrep -x xfce4-panel >/dev/null && break
    sleep 0.2
  done
  xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false
) >>"$LOG" 2>&1 &

data_dir=${CODEVISOR_DATA_DIR:?}
mkdir -p "$data_dir"
printf '{ "vnc": { "port": %s, "name": "Desktop", "desktop": "xfce", "defaultSize": "%s" }, "devContainerDesktop": true }\n' \
  "$PORT" "$GEOMETRY" >"$data_dir/screen-sharing.json"
cat >/tmp/desktop.env <<ENV
export DISPLAY='$DISPLAY'
export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
export DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS'
ENV
echo "[container] desktop on $DISPLAY (VNC localhost:$PORT)"

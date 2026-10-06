#!/bin/sh
# Gives a dev container an Xfce desktop over TigerVNC, run by
# dev-container-entry.sh when CODEVISOR_DEV_DESKTOP=1 (the runner sets it
# for CODEVISOR_DEV_CONTAINER_DESKTOP=1). The Codevisor app views it as a
# Screen Sharing pane, and Computer Use drives it through AT-SPI: the same
# desktop scripts/vnc-desktop.sh sets up on a real Linux machine, without
# systemd, which a container doesn't run.
#
# The container's filesystem is fresh each boot, so the packages are installed
# each boot too, from .debs and package lists kept in the worktree's
# tmp-mounted state: only the first boot downloads them.
#
# Xvnc listens on localhost only, with no VNC password: only codevisor-server
# in the same container reaches it. On success this writes the server's
# screen-sharing.json and /tmp/desktop.env, the display and session bus for
# the server (and the Computer Use helper it spawns) to inherit.
set -eu

DISPLAY_NUMBER=1
GEOMETRY=1440x900
PORT=$((5900 + DISPLAY_NUMBER))
APT_STATE=/codevisor-state/apt
LOG=/tmp/desktop.log
# xclip and xdotool for checking the clipboard and input from a shell; Mousepad
# and the terminal to copy and paste in; python3-gi and the Atspi/Gtk typelibs
# for the Computer Use helper.
PACKAGES="tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal mousepad dbus-x11
  at-spi2-core python3-gi gir1.2-atspi-2.0 gir1.2-gtk-3.0 xclip xdotool x11-xserver-utils
  fonts-dejavu-core adwaita-icon-theme"

if ! command -v Xvnc >/dev/null 2>&1; then
  echo "[container] installing the desktop (Xfce, TigerVNC, accessibility)"
  mkdir -p "$APT_STATE/archives/partial" "$APT_STATE/lists/partial"
  # Containers of one worktree share this cache; apt's own locks don't reach across VMs.
  exec 8>"$APT_STATE/.lock"
  flock 8
  apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -qq \
      -o Dir::Cache::archives="$APT_STATE/archives" -o Dir::State::lists="$APT_STATE/lists" "$@"
  }
  # shellcheck disable=SC2086 # PACKAGES is a word list
  if ! { [ -e "$APT_STATE/updated" ] && apt_get install -y --no-install-recommends $PACKAGES >/dev/null; }; then
    # No lists yet, or they name versions the mirror no longer has.
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
# One session bus for the desktop, its accessibility bus and the server's Computer Use helper.
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
# xfwm4's compositor only adds repaints to stream (as scripts/vnc-desktop.sh turns it off).
(
  for _ in $(seq 1 100); do
    pgrep -x xfce4-panel >/dev/null && break
    sleep 0.2
  done
  xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false
) >>"$LOG" 2>&1 &

data_dir=${CODEVISOR_DATA_DIR:?}
mkdir -p "$data_dir"
# devContainerDesktop marks the file as this script's: a boot without the desktop removes it.
printf '{ "vnc": { "port": %s, "name": "Desktop", "desktop": "xfce", "defaultSize": "%s" }, "devContainerDesktop": true }\n' \
  "$PORT" "$GEOMETRY" >"$data_dir/screen-sharing.json"
cat >/tmp/desktop.env <<ENV
export DISPLAY='$DISPLAY'
export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
export DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS'
ENV
echo "[container] desktop on $DISPLAY (VNC localhost:$PORT)"

#!/bin/sh
# Xvnc on :1 (port 5901) with VNC authentication and a solid root colour the
# interop tests assert on. GEOMETRY, PASSWORD and ROOT_COLOR come from
# apps/screen-sharing-rig/scripts/vnc-interop.mjs.
set -eu
: "${GEOMETRY:=1024x768}" "${PASSWORD:=codevisor}" "${ROOT_COLOR:=#336699}"
mkdir -p /root/.vnc
printf '%s\n' "$PASSWORD" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
Xvnc :1 -geometry "$GEOMETRY" -depth 24 -rfbport 5901 -SecurityTypes VncAuth \
  -PasswordFile /root/.vnc/passwd -AlwaysShared -desktop "codevisor-interop" \
  -BlacklistThreshold 1000 &  # parallel test connections must not trip the brute-force blacklist
xvnc=$!
ready=0
for _ in $(seq 1 50); do
  # A desktop sets a root pointer (Xfce: left_ptr); bare X has none, and Xvnc then sends a hidden cursor.
  DISPLAY=:1 xsetroot -solid "$ROOT_COLOR" -cursor_name left_ptr 2>/dev/null && ready=1 && break
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "vnc-interop: xsetroot never succeeded" >&2; exit 1; }
# Something that changes every second, bottom-right, clear of the pixels the tests assert on:
# a continuous-updates client must keep receiving updates without asking.
DISPLAY=:1 xclock -digital -update 1 -geometry 200x40-0-0 &
# Photo-like content at 600,300 (clear of the pixels the tests sample): what makes Tight use JPEG (851-2313).
DISPLAY=:1 display -size 320x200 -seed 7 plasma:fractal -geometry +600+300 &
# Ready only once that window is mapped (ImageMagick takes a moment to render the fractal).
DISPLAY=:1 timeout 20 xdotool search --sync --onlyvisible --class display >/dev/null || {
  echo "vnc-interop: the plasma window never appeared" >&2
  exit 1
}
# Without a window manager `display` ignores -geometry; put it where the tests sample.
DISPLAY=:1 xdotool search --onlyvisible --class display windowmove 600 300
DISPLAY=:1 xdotool search --onlyvisible --class display getwindowgeometry | sed 's/^/vnc-interop: plasma /'
# Typing sink (851-2318), bottom-left: an xterm that puts each typed line on the clipboard as
# "typed:<line>", which Xvnc then announces to clients. No window manager: X focus follows the pointer.
LANG=C.UTF-8 DISPLAY=:1 xterm -u8 -geometry 60x3+20+560 -name typing-sink -e sh -c \
  'while IFS= read -r line; do printf "typed:%s" "$line" | xclip -i -selection clipboard; done' &
DISPLAY=:1 timeout 20 xdotool search --sync --onlyvisible --classname typing-sink >/dev/null || {
  echo "vnc-interop: the typing sink never appeared" >&2
  exit 1
}
sleep 0.5
# Clipboard echo (851-2316): reading the clipboard is the "paste" that makes Xvnc ask a
# client for the text it announced; writing it back as "echo:<text>" makes Xvnc announce it.
(
  while :; do
    text=$(DISPLAY=:1 xclip -o -selection clipboard 2>/dev/null) || text=""
    case "$text" in
      "" | echo:* | typed:*) ;;
      *) printf 'echo:%s' "$text" | DISPLAY=:1 xclip -i -selection clipboard ;;
    esac
    sleep 0.3
  done
) &
echo "vnc-interop: ready"
wait "$xvnc"

# The L3 interop server (docs/plans/vnc-validation.md): TigerVNC's Xvnc with a
# known desktop, for `bun run vnc:interop`. Pinned so results are comparable.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    tigervnc-standalone-server=1.15.0+dfsg-2.1~deb13u1 tigervnc-tools x11-xserver-utils xdotool xclip xfonts-base x11-apps imagemagick xterm \
  && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
EXPOSE 5901
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]

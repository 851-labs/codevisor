#!/bin/sh
# HerdMan installer — https://www.herdman.dev/install.sh
#
#   curl -fsSL https://www.herdman.dev/install.sh | sh
#
# macOS  : installs the HerdMan app into /Applications.
# Linux  : installs herdman-server and sets it up as a systemd service so the
#          HerdMan app on your Mac can connect to this machine.
#
# Options (environment variables):
#   HERDMAN_VERSION      install a specific version instead of the latest
#   HERDMAN_INSTALL_DIR  Linux server install dir   (default: ~/.herdman/server, /opt/herdman as root)
#   HERDMAN_BIN_DIR      Linux symlink dir          (default: ~/.local/bin, /usr/local/bin as root)
#   HERDMAN_PORT         Linux server port          (default: 49361)
#   HERDMAN_NO_SERVICE   set to 1 to skip systemd setup on Linux

set -eu

RELEASE_BASE="https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/herdman"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"

fetch() { curl -fsSL "$1"; }
download() { curl -fSL --progress-bar -o "$2" "$1"; }

resolve_version() {
  if [ -n "${HERDMAN_VERSION:-}" ]; then
    printf '%s' "${HERDMAN_VERSION#v}"
    return
  fi
  manifest=$(fetch "$RELEASE_BASE/latest.json") || fail "could not fetch $RELEASE_BASE/latest.json"
  version=$(printf '%s' "$manifest" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p')
  [ -n "$version" ] || fail "could not parse version from release manifest"
  printf '%s' "$version"
}

tmp_dir=$(mktemp -d)
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

install_macos() {
  version="$1"
  app_dest="/Applications/HerdMan.app"

  say "Installing HerdMan $version for macOS"

  archive_url="$RELEASE_BASE/v$version/HerdMan.dmg"
  archive="$tmp_dir/HerdMan.dmg"
  kind="dmg"
  if ! curl -fsSL -o "$archive" "$archive_url"; then
    # Releases published before the DMG existed only have the zip.
    archive_url="$RELEASE_BASE/v$version/HerdMan-macOS.zip"
    archive="$tmp_dir/HerdMan-macOS.zip"
    kind="zip"
    say "Downloading $archive_url"
    download "$archive_url" "$archive"
  fi

  app_src=""
  if [ "$kind" = "dmg" ]; then
    mount_point="$tmp_dir/mnt"
    say "Mounting disk image"
    hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mount_point" "$archive"
    trap 'hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 || true; cleanup' EXIT
    app_src="$mount_point/HerdMan.app"
  else
    say "Extracting archive"
    ditto -xk "$archive" "$tmp_dir/extract"
    app_src="$tmp_dir/extract/HerdMan.app"
  fi
  [ -d "$app_src" ] || fail "HerdMan.app not found in downloaded archive"

  if [ -d "$app_dest" ]; then
    say "Replacing existing $app_dest"
    osascript -e 'tell application "HerdMan" to quit' >/dev/null 2>&1 || true
    rm -rf "$app_dest"
  fi

  say "Copying HerdMan.app to /Applications"
  ditto "$app_src" "$app_dest"

  if [ "$kind" = "dmg" ]; then
    hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 || true
    trap cleanup EXIT
  fi

  say "HerdMan $version installed"
  note "Launching HerdMan…"
  open "$app_dest" || true
}

install_linux() {
  version="$1"

  command -v tar >/dev/null 2>&1 || fail "tar is required"

  case "$(uname -m)" in
    x86_64 | amd64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) fail "unsupported architecture: $(uname -m) (need x86_64 or arm64)" ;;
  esac

  if [ "$(id -u)" = "0" ]; then
    install_dir="${HERDMAN_INSTALL_DIR:-/opt/herdman}"
    bin_dir="${HERDMAN_BIN_DIR:-/usr/local/bin}"
  else
    install_dir="${HERDMAN_INSTALL_DIR:-$HOME/.herdman/server}"
    bin_dir="${HERDMAN_BIN_DIR:-$HOME/.local/bin}"
  fi
  port="${HERDMAN_PORT:-49361}"

  target="linux-$arch"
  archive_url="$RELEASE_BASE/v$version/herdman-server-$target.tar.gz"
  archive="$tmp_dir/herdman-server.tar.gz"

  say "Installing herdman-server $version ($target)"
  say "Downloading $archive_url"
  download "$archive_url" "$archive"

  if command -v sha256sum >/dev/null 2>&1; then
    expected=$(fetch "$archive_url.sha256" 2>/dev/null | awk '{print $1}') || expected=""
    if [ -n "$expected" ]; then
      actual=$(sha256sum "$archive" | awk '{print $1}')
      [ "$actual" = "$expected" ] || fail "checksum mismatch: expected $expected, got $actual"
      say "Checksum verified"
    fi
  fi

  say "Extracting to $install_dir"
  rm -rf "$install_dir"
  mkdir -p "$install_dir"
  tar -xzf "$archive" -C "$install_dir"

  mkdir -p "$bin_dir"
  ln -sf "$install_dir/bin/herdman-server" "$bin_dir/herdman-server"
  ln -sf "$install_dir/bin/herdman-terminal-proxy" "$bin_dir/herdman-terminal-proxy"
  say "Linked herdman-server into $bin_dir"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) note "note: $bin_dir is not on your PATH" ;;
  esac

  serve_cmd="$install_dir/bin/herdman-server serve --host 0.0.0.0 --port $port --auth token"

  if [ "${HERDMAN_NO_SERVICE:-0}" = "1" ] || ! command -v systemctl >/dev/null 2>&1; then
    say "herdman-server $version installed"
    note "Start it with:"
    note "  $serve_cmd"
  elif [ "$(id -u)" = "0" ]; then
    say "Setting up systemd service (system)"
    cat > /etc/systemd/system/herdman-server.service <<UNIT
[Unit]
Description=HerdMan ACP server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$serve_cmd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now herdman-server.service
    say "herdman-server is running (systemctl status herdman-server)"
  else
    say "Setting up systemd service (user)"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/herdman-server.service" <<UNIT
[Unit]
Description=HerdMan ACP server
After=network-online.target

[Service]
ExecStart=$serve_cmd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now herdman-server.service
    say "herdman-server is running (systemctl --user status herdman-server)"
    note "To keep it running after you log out:"
    note "  sudo loginctl enable-linger $USER"
  fi

  say "Connect from the HerdMan app"
  note "1. Get a pairing token on this machine:"
  note "     curl -s -X POST http://127.0.0.1:$port/v1/auth/pairing-token"
  note "2. In HerdMan on your Mac: Machines → Add Machine, then enter"
  note "   this machine's address (port $port) and the token."
}

main() {
  version=$(resolve_version)
  case "$(uname -s)" in
    Darwin) install_macos "$version" ;;
    Linux) install_linux "$version" ;;
    *) fail "unsupported platform: $(uname -s) (HerdMan supports macOS and Linux)" ;;
  esac
}

main

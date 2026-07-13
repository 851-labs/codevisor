#!/bin/sh
# Codevisor installer — https://www.codevisor.dev/install.sh
#
#   curl -fsSL https://www.codevisor.dev/install.sh | sh
#
# macOS  : installs the Codevisor app into /Applications.
# Linux  : installs codevisor-server and sets it up as a systemd service so the
#          Codevisor app on your Mac can connect to this machine.
#
# Options (environment variables):
#   CODEVISOR_VERSION      install a specific version instead of the latest
#   CODEVISOR_INSTALL_DIR  Linux server install dir   (default: ~/.codevisor/server, /opt/codevisor as root)
#   CODEVISOR_BIN_DIR      Linux symlink dir          (default: ~/.local/bin, /usr/local/bin as root)
#   CODEVISOR_PORT         Linux server port          (default: 49361)
#   CODEVISOR_NO_SERVICE   set to 1 to skip systemd setup on Linux
#
# The former HERDMAN_* option names remain accepted for upgrade compatibility.

set -eu

RELEASE_BASE="https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"

fetch() { curl -fsSL "$1"; }
download() { curl -fSL --progress-bar -o "$2" "$1"; }

resolve_version() {
  requested_version="${CODEVISOR_VERSION:-${HERDMAN_VERSION:-}}"
  if [ -n "$requested_version" ]; then
    printf '%s' "${requested_version#v}"
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
  app_dest="/Applications/Codevisor.app"
  legacy_app_dest="/Applications/HerdMan.app"

  say "Installing Codevisor $version for macOS"

  archive_url="$RELEASE_BASE/v$version/Codevisor.dmg"
  archive="$tmp_dir/Codevisor.dmg"
  kind="dmg"
  if ! curl -fsSL -o "$archive" "$archive_url"; then
    # Releases published before the DMG existed only have the zip.
    archive_url="$RELEASE_BASE/v$version/Codevisor-macOS.zip"
    archive="$tmp_dir/Codevisor-macOS.zip"
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
    app_src="$mount_point/Codevisor.app"
  else
    say "Extracting archive"
    ditto -xk "$archive" "$tmp_dir/extract"
    app_src="$tmp_dir/extract/Codevisor.app"
  fi
  [ -d "$app_src" ] || fail "Codevisor.app not found in downloaded archive"

  osascript -e 'tell application id "com.851labs.HerdMan" to quit' >/dev/null 2>&1 || true
  [ ! -d "$app_dest" ] || { say "Replacing existing $app_dest"; rm -rf "$app_dest"; }
  [ ! -d "$legacy_app_dest" ] || { say "Removing former $legacy_app_dest"; rm -rf "$legacy_app_dest"; }

  say "Copying Codevisor.app to /Applications"
  ditto "$app_src" "$app_dest"

  if [ "$kind" = "dmg" ]; then
    hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 || true
    trap cleanup EXIT
  fi

  say "Codevisor $version installed"
  note "Launching Codevisor…"
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
    install_dir="${CODEVISOR_INSTALL_DIR:-${HERDMAN_INSTALL_DIR:-/opt/codevisor}}"
    bin_dir="${CODEVISOR_BIN_DIR:-${HERDMAN_BIN_DIR:-/usr/local/bin}}"
  else
    install_dir="${CODEVISOR_INSTALL_DIR:-${HERDMAN_INSTALL_DIR:-$HOME/.codevisor/server}}"
    bin_dir="${CODEVISOR_BIN_DIR:-${HERDMAN_BIN_DIR:-$HOME/.local/bin}}"
  fi
  port="${CODEVISOR_PORT:-${HERDMAN_PORT:-49361}}"

  target="linux-$arch"
  archive_url="$RELEASE_BASE/v$version/codevisor-server-$target.tar.gz"
  archive="$tmp_dir/codevisor-server.tar.gz"

  say "Installing codevisor-server $version ($target)"
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
  ln -sf "$install_dir/bin/codevisor-server" "$bin_dir/codevisor-server"
  ln -sf "$install_dir/bin/codevisor-terminal-proxy" "$bin_dir/codevisor-terminal-proxy"
  rm -f "$bin_dir/herdman-server" "$bin_dir/herdman-terminal-proxy"
  say "Linked codevisor-server into $bin_dir"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) note "note: $bin_dir is not on your PATH" ;;
  esac

  serve_cmd="$install_dir/bin/codevisor-server serve --host 0.0.0.0 --port $port --auth token"

  no_service="${CODEVISOR_NO_SERVICE:-${HERDMAN_NO_SERVICE:-0}}"
  if [ "$no_service" = "1" ] || ! command -v systemctl >/dev/null 2>&1; then
    say "codevisor-server $version installed"
    note "Start it with:"
    note "  $serve_cmd"
  elif [ "$(id -u)" = "0" ]; then
    say "Setting up systemd service (system)"
    systemctl disable --now herdman-server.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/herdman-server.service
    cat > /etc/systemd/system/codevisor-server.service <<UNIT
[Unit]
Description=Codevisor ACP server
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
    systemctl enable --now codevisor-server.service
    say "codevisor-server is running (systemctl status codevisor-server)"
  else
    say "Setting up systemd service (user)"
    systemctl --user disable --now herdman-server.service >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/herdman-server.service"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/codevisor-server.service" <<UNIT
[Unit]
Description=Codevisor ACP server
After=network-online.target

[Service]
ExecStart=$serve_cmd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now codevisor-server.service
    say "codevisor-server is running (systemctl --user status codevisor-server)"
    note "To keep it running after you log out:"
    note "  sudo loginctl enable-linger $USER"
  fi

  say "Connect from the Codevisor app"
  note "1. Get a pairing token on this machine:"
  note "     curl -s -X POST http://127.0.0.1:$port/v1/auth/pairing-token"
  note "2. In Codevisor on your Mac: Machines → Add Machine, then enter"
  note "   this machine's address (port $port) and the token."
}

main() {
  version=$(resolve_version)
  case "$(uname -s)" in
    Darwin) install_macos "$version" ;;
    Linux) install_linux "$version" ;;
    *) fail "unsupported platform: $(uname -s) (Codevisor supports macOS and Linux)" ;;
  esac
}

main

#!/bin/sh

set -eu

RELEASE_REPOSITORY="851-labs/codevisor"
STABLE_MANIFEST_URL="https://updates.codevisor.dev/server/stable.json"
RELEASE_DOWNLOAD_BASE="https://github.com/$RELEASE_REPOSITORY/releases/download"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"

fetch() { curl -fsSL "$@"; }
download() {
  if [ -t 1 ]; then
    curl -fSL --progress-bar -o "$2" "$1"
  else
    curl -fsSL -o "$2" "$1"
  fi
}

resolve_version() {
  requested_version="${CODEVISOR_VERSION:-${HERDMAN_VERSION:-}}"
  if [ -n "$requested_version" ]; then
    printf '%s' "${requested_version#v}"
    return
  fi
  release=$(fetch -H 'Cache-Control: no-cache' "$STABLE_MANIFEST_URL") ||
    fail "could not fetch the latest stable release from $STABLE_MANIFEST_URL; retry or set CODEVISOR_VERSION"
  version=$(printf '%s' "$release" | tr '\n' ' ' | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p')
  [ -n "$version" ] || fail "could not parse a stable version from $STABLE_MANIFEST_URL; retry or set CODEVISOR_VERSION"
  printf '%s' "$version"
}

tmp_dir=$(mktemp -d)
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

APP_PATH="/Applications/Codevisor.app"

install_macos() {
  version="$1"
  app_dest="$APP_PATH"
  legacy_app_dest="/Applications/HerdMan.app"

  say "Installing Codevisor $version for macOS"

  archive="$tmp_dir/Codevisor.dmg"
  kind="dmg"
  if curl -fsSL -o "$archive" "$RELEASE_DOWNLOAD_BASE/v$version/Codevisor-arm64.dmg"; then
    archive_url="$RELEASE_DOWNLOAD_BASE/v$version/Codevisor-arm64.dmg"
  elif curl -fsSL -o "$archive" "$RELEASE_DOWNLOAD_BASE/v$version/Codevisor.dmg"; then
    archive_url="$RELEASE_DOWNLOAD_BASE/v$version/Codevisor.dmg"
  else
    archive_url="$RELEASE_DOWNLOAD_BASE/v$version/Codevisor-macOS.zip"
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

  bin_dir="${CODEVISOR_BIN_DIR:-${HERDMAN_BIN_DIR:-$HOME/.local/bin}}"
  runtime_bin="$app_dest/Contents/Resources/server/darwin-arm64/bin"
  if [ -x "$runtime_bin/codevisor" ]; then
    mkdir -p "$bin_dir"
    ln -sf "$runtime_bin/codevisor" "$bin_dir/codevisor"
    ln -sf "$runtime_bin/codevisor-server" "$bin_dir/codevisor-server"
    ln -sf "$runtime_bin/codevisor-terminal-proxy" "$bin_dir/codevisor-terminal-proxy"
    say "Linked codevisor into $bin_dir"
    case ":$PATH:" in
      *":$bin_dir:"*) ;;
      *) note "note: $bin_dir is not on your PATH" ;;
    esac
  else
    note "note: bundled CLI not found in the app; skipping PATH setup"
  fi

  say "Codevisor $version installed"
  note "Launching Codevisor…"
  open "$app_dest" || true
}

systemd_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g'
}

install_server() {
  version="$1"
  os="$2"

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
  data_dir="${CODEVISOR_DATA_DIR:-$HOME/.codevisor/data}"
  logs_dir="${CODEVISOR_LOGS_DIR:-$HOME/.codevisor/logs}"
  port="${CODEVISOR_PORT:-${HERDMAN_PORT:-49361}}"

  target="$os-$arch"
  archive_url="$RELEASE_DOWNLOAD_BASE/v$version/codevisor-server-$target.tar.gz"
  archive="$tmp_dir/codevisor-server.tar.gz"

  say "Installing codevisor-server $version ($target)"
  say "Downloading $archive_url"
  download "$archive_url" "$archive"

  sha256_tool=""
  if command -v sha256sum >/dev/null 2>&1; then
    sha256_tool="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    sha256_tool="shasum -a 256"
  fi
  if [ -n "$sha256_tool" ]; then
    expected=$(fetch "$archive_url.sha256" 2>/dev/null | awk '{print $1}') || expected=""
    if [ -n "$expected" ]; then
      actual=$($sha256_tool "$archive" | awk '{print $1}')
      [ "$actual" = "$expected" ] || fail "checksum mismatch: expected $expected, got $actual"
      say "Checksum verified"
    fi
  fi

  say "Extracting to $install_dir"
  rm -rf "$install_dir"
  mkdir -p "$install_dir"
  tar -xzf "$archive" -C "$install_dir"

  mkdir -p "$bin_dir"
  ln -sf "$install_dir/bin/codevisor" "$bin_dir/codevisor"
  ln -sf "$install_dir/bin/codevisor-server" "$bin_dir/codevisor-server"
  ln -sf "$install_dir/bin/codevisor-terminal-proxy" "$bin_dir/codevisor-terminal-proxy"
  rm -f "$bin_dir/herdman-server" "$bin_dir/herdman-terminal-proxy"
  say "Linked codevisor into $bin_dir"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) note "note: $bin_dir is not on your PATH" ;;
  esac

  mkdir -p "$data_dir" "$logs_dir"
  serve_cmd="\"$(systemd_escape "$install_dir/bin/codevisor-server")\" serve --host 0.0.0.0 --port $port --auth token --db \"$(systemd_escape "$data_dir/codevisor-server.sqlite")\""
  data_environment=""
  if [ -n "${CODEVISOR_DATA_DIR:-}" ]; then
    data_environment="Environment=\"CODEVISOR_DATA_DIR=$(systemd_escape "$CODEVISOR_DATA_DIR")\""
  fi

  no_service="${CODEVISOR_NO_SERVICE:-${HERDMAN_NO_SERVICE:-0}}"
  if [ "$os" = "darwin" ]; then
    say "codevisor-server $version installed"
    note "Start it with:"
    note "  codevisor start"
    note "Run it again after a reboot; it does not start automatically on macOS."
  elif [ "$no_service" = "1" ] || ! command -v systemctl >/dev/null 2>&1 ||
    ! systemctl show --property=Version >/dev/null 2>&1; then
    say "codevisor-server $version installed"
    note "Start it with:"
    note "  codevisor start"
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
$data_environment
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable codevisor-server.service
    systemctl restart codevisor-server.service
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
$data_environment
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable codevisor-server.service
    systemctl --user restart codevisor-server.service
    say "codevisor-server is running (systemctl --user status codevisor-server)"
    note "To keep it running after you log out:"
    note "  sudo loginctl enable-linger $USER"
  fi

  if [ -n "${CODEVISOR_INVITE:-}" ]; then
    say "Joining your Codevisor account"
    invite="$CODEVISOR_INVITE"
    unset CODEVISOR_INVITE
    if [ -n "${CODEVISOR_MACHINE_NAME:-}" ]; then
      printf '%s\n' "$invite" |
        "$bin_dir/codevisor" auth login --invite - --name "$CODEVISOR_MACHINE_NAME" --port "$port"
    else
      printf '%s\n' "$invite" | "$bin_dir/codevisor" auth login --invite - --port "$port"
    fi
  elif [ "${CODEVISOR_NO_SETUP:-0}" = "1" ]; then
    note "Finish onboarding later with: codevisor setup"
  elif [ -t 1 ] && [ -r /dev/tty ]; then
    say "Finishing setup"
    "$bin_dir/codevisor" setup --port "$port" < /dev/tty ||
      note "Finish onboarding with: codevisor setup"
  else
    say "Connect this machine to your Codevisor account"
    note "Finish onboarding on this machine with: codevisor setup"
    note "(It signs the machine in so it appears in your Codevisor apps.)"
  fi
}

is_apple_silicon() {
  [ "$(uname -m)" = "arm64" ] || [ "$(sysctl -in hw.optional.arm64 2>/dev/null)" = "1" ]
}

confirm_intel_mac_server() {
  printf '\033[1;33m==>\033[0m %s\n' "The Codevisor app is not supported on Intel Macs"
  note "The macOS app requires Apple silicon. You can still run codevisor-server on this"
  note "Mac and connect to it from the Codevisor app on another machine."
  if [ -d "$APP_PATH" ]; then
    note "The Codevisor app already in /Applications no longer receives updates on this"
    note "Mac; installing the server stops its bundled server, which uses the same port."
  fi
  case "${CODEVISOR_INSTALL_SERVER:-}" in
    1) return 0 ;;
    0) fail "not installing codevisor-server (CODEVISOR_INSTALL_SERVER=0)" ;;
  esac
  if ! (exec </dev/tty) 2>/dev/null; then
    fail "no terminal to confirm with; rerun with CODEVISOR_INSTALL_SERVER=1 to install codevisor-server"
  fi
  printf 'Install codevisor-server instead? [y/N] ' >/dev/tty
  answer=""
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y | Y | yes | Yes | YES) ;;
    *)
      say "Nothing installed"
      exit 0
      ;;
  esac
}

stop_unsupported_mac_app() {
  [ -d "$APP_PATH" ] || return 0
  say "Stopping the Codevisor app and its bundled server"
  osascript -e 'if application id "com.851labs.HerdMan" is running then tell application id "com.851labs.HerdMan" to quit' >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/com.851labs.Codevisor.ServerAgent" >/dev/null 2>&1 || true
  note "Move $APP_PATH to the Trash so it does not start its server again."
}

main() {
  case "$(uname -s)" in
    Darwin)
      if is_apple_silicon; then
        version=$(resolve_version)
        install_macos "$version"
      else
        confirm_intel_mac_server
        version=$(resolve_version)
        stop_unsupported_mac_app
        install_server "$version" darwin
      fi
      ;;
    Linux)
      version=$(resolve_version)
      install_server "$version" linux
      ;;
    *) fail "unsupported platform: $(uname -s) (Codevisor supports macOS and Linux)" ;;
  esac
}

main

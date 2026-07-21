#!/usr/bin/env bash
set -euo pipefail

echo "Provisioning $(scutil --get ComputerName 2>/dev/null || hostname) ($(uname -m))"
sw_vers
df -h /Applications

if developer_dir="$("$(dirname "$0")/resolve-xcode.sh" 2>/dev/null)"; then
  echo "Full Xcode already exists at $developer_dir"
else
  available_kb="$(df -Pk /Applications | awk 'NR == 2 { print $4 }')"
  minimum_kb=$((45 * 1024 * 1024))
  if [[ -z "$available_kb" || "$available_kb" -lt "$minimum_kb" ]]; then
    echo "At least 45 GiB free is required to install and initialize Xcode." >&2
    exit 1
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required to install the Mac App Store CLI." >&2
    exit 1
  fi
  if ! command -v mas >/dev/null 2>&1; then
    brew install mas
  fi
  mas version
  # `get` acquires the free app when necessary and installs it for an App
  # Store account already signed in on the runner user.
  mas get 497799835
  developer_dir="$("$(dirname "$0")/resolve-xcode.sh")"
fi

if ! sudo -n true; then
  echo "Xcode is installed, but the runner account needs passwordless sudo for one-time initialization." >&2
  echo "Run these commands once on the runner, then dispatch this workflow again:" >&2
  echo "  sudo '$developer_dir/usr/bin/xcodebuild' -license accept" >&2
  echo "  sudo '$developer_dir/usr/bin/xcodebuild' -runFirstLaunch" >&2
  exit 1
fi

sudo -n "$developer_dir/usr/bin/xcodebuild" -license accept
sudo -n "$developer_dir/usr/bin/xcodebuild" -runFirstLaunch
DEVELOPER_DIR="$developer_dir" xcodebuild -version
DEVELOPER_DIR="$developer_dir" xcrun swift --version
echo "Full Xcode is ready at $developer_dir"

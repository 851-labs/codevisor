#!/usr/bin/env bash
set -euo pipefail

# Self-hosted runners often register while CommandLineTools is selected even
# though full Xcode is installed. Prefer the conventional app, then any
# versioned Xcode bundle, without mutating the machine-wide xcode-select state.
for developer_dir in \
  /Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode*.app/Contents/Developer; do
  if [[ -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "$developer_dir"
    exit 0
  fi
done

echo "A full Xcode installation is required under /Applications." >&2
exit 1

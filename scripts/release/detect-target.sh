#!/usr/bin/env bash
set -euo pipefail

os="$(uname -s)"
arch="$(uname -m)"

case "$os:$arch" in
  Darwin:arm64)
    echo "darwin-arm64"
    ;;
  Darwin:x86_64)
    echo "darwin-x64"
    ;;
  Linux:x86_64)
    echo "linux-x64"
    ;;
  Linux:aarch64 | Linux:arm64)
    echo "linux-arm64"
    ;;
  *)
    echo "unsupported target: $os $arch" >&2
    exit 1
    ;;
esac

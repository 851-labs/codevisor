#!/bin/sh
set -eu

add_bun_to_path() {
  command -v bun >/dev/null 2>&1 && return 0

  for dir in \
    "${HOME:-}/.local/share/vite-plus/bin" \
    "${HOME:-}/.local/share/vite-plus/fallback-bin" \
    "${HOME:-}/.bun/bin" \
    "${HOMEBREW_PREFIX:-/opt/homebrew}/bin"; do
    if [ -x "$dir/bun" ]; then
      PATH="$PATH:$dir"
      export PATH
      return 0
    fi
  done

  return 1
}

hook_cannot_stop_git() {
  [ "${1:-}" = run ] || return 1

  case "${2:-}" in
    post-*) return 0 ;;
    *) return 1 ;;
  esac
}

if add_bun_to_path; then
  exec bun x lefthook "$@"
fi

if hook_cannot_stop_git "$@"; then
  [ ! -t 2 ] || echo "Skipping the $2 hook: bun isn't installed or on PATH." >&2
  exit 0
fi

echo "Can't run lefthook $*: bun isn't installed or on PATH. Install bun or add it to PATH, then retry." >&2
exit 1

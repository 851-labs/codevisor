#!/usr/bin/env bash

: "${GITHUB_API_CURL:=/usr/bin/curl}"

github_api() {
  printf 'Authorization: Bearer %s\n' "${GH_TOKEN:?GH_TOKEN must be set}" |
    "$GITHUB_API_CURL" -sS --fail-with-body --retry 3 --retry-all-errors --retry-delay 2 -H @- \
      -H "Accept: application/vnd.github+json" "${GITHUB_API_URL:-https://api.github.com}/$1"
}

#!/usr/bin/env bash

github_api() {
  curl -fsS --retry 2 -H "Authorization: Bearer ${GH_TOKEN:?GH_TOKEN must be set}" \
    -H "Accept: application/vnd.github+json" "${GITHUB_API_URL:-https://api.github.com}/$1"
}

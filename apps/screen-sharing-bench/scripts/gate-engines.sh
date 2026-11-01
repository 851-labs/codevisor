#!/usr/bin/env bash
set -euo pipefail

v1=0 v2=0
while IFS= read -r path; do
  case "$path" in
    packages/swift/ScreenSharing/Sources/ScreenSharingV2/* | packages/swift/ScreenSharing/Tests/ScreenSharingV2Tests/* | \
      apps/screen-sharing-bench/Sources/CodevisorBench/EngineV2/* | \
      apps/screen-sharing-bench/Sources/CodevisorBench/Loopback/V2/* | packages/net/*)
      v2=1 ;;
    packages/swift/ScreenSharing/Sources/ScreenSharingWebRTC/* | \
      packages/swift/ScreenSharing/Tests/ScreenSharingWebRTCTests/* | \
      packages/swift/CodevisorCoreMac/Sources/CodevisorCoreMac/ScreenSharing/*)
      v1=1 ;;
    packages/swift/ScreenSharing/* | apps/screen-sharing-bench/* | .github/workflows/screen-sharing-bench.yml)
      v1=1 v2=1 ;;
  esac
done

if ((v1 && v2)); then
  echo v1,v2
elif ((v2)); then
  echo v2
else
  echo v1
fi

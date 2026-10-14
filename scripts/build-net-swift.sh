#!/usr/bin/env bash
set -euo pipefail
out="${1:?usage: build-net-swift.sh <output-dir>}"
net_root="$(cd "$(dirname "$0")/../packages/net" && pwd)"
cd "$net_root"
export IPHONEOS_DEPLOYMENT_TARGET=17.0 MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_PROFILE_RELEASE_OPT_LEVEL=s
targets=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
: "${RUSTUP_TOOLCHAIN:?run through scripts/net-artifact.mjs ensure-swift}"
rustup target add "${targets[@]}" >/dev/null
for target in "${targets[@]}"; do
  cargo build --release --locked -p codevisor-net-ffi --lib --target "$target"
done
lib=libcodevisor_net_ffi.a
work="$out/work"
rm -rf "$work" && mkdir -p "$work/macos" "$work/ios-sim" "$work/headers" "$work/swift"
lipo -create target/aarch64-apple-darwin/release/$lib target/x86_64-apple-darwin/release/$lib \
  -output "$work/macos/$lib"
lipo -create target/aarch64-apple-ios-sim/release/$lib target/x86_64-apple-ios/release/$lib \
  -output "$work/ios-sim/$lib"

cargo run --release --locked -p codevisor-net-ffi --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-darwin/release/$lib --language swift --out-dir "$work/swift"
cp "$work/swift/codevisor_net_ffiFFI.h" "$work/headers/"
cp "$work/swift/codevisor_net_ffiFFI.modulemap" "$work/headers/module.modulemap"

rm -rf "$out/CodevisorNetFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$work/macos/$lib" -headers "$work/headers" \
  -library target/aarch64-apple-ios/release/$lib -headers "$work/headers" \
  -library "$work/ios-sim/$lib" -headers "$work/headers" \
  -output "$out/CodevisorNetFFI.xcframework" >/dev/null
cp "$work/swift/codevisor_net_ffi.swift" "$out/codevisor_net_ffi.swift"
rm -rf "$work"
echo "$out/CodevisorNetFFI.xcframework"

#!/usr/bin/env bash
# Lab branch only (851-3815): macOS arm64 alone, so a bench dispatch fits in 30 minutes.
set -euo pipefail
out="${1:?usage: build-net-swift.sh <output-dir>}"
net_root="$(cd "$(dirname "$0")/../packages/net" && pwd)"
cd "$net_root"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_PROFILE_RELEASE_OPT_LEVEL=s
target=aarch64-apple-darwin
: "${RUSTUP_TOOLCHAIN:?run through scripts/net-artifact.mjs ensure-swift}"
rustup target add "$target" >/dev/null
cargo build --release --locked -p codevisor-net-ffi --lib --target "$target"
lib=libcodevisor_net_ffi.a
work="$out/work"
rm -rf "$work" && mkdir -p "$work/headers" "$work/swift"
cargo run --release --locked -p codevisor-net-ffi --bin uniffi-bindgen -- generate \
  --library target/$target/release/$lib --language swift --out-dir "$work/swift"
cp "$work/swift/codevisor_net_ffiFFI.h" crates/codevisor-net-ffi/include/codevisor_media.h "$work/headers/"
sed 's|header "codevisor_net_ffiFFI.h"|&\n    header "codevisor_media.h"|' "$work/swift/codevisor_net_ffiFFI.modulemap" \
  > "$work/headers/module.modulemap"
rm -rf "$out/CodevisorNetFFI.xcframework"
xcodebuild -create-xcframework -library target/$target/release/$lib -headers "$work/headers" \
  -output "$out/CodevisorNetFFI.xcframework" >/dev/null
cp "$work/swift/codevisor_net_ffi.swift" "$out/codevisor_net_ffi.swift"
rm -rf "$work"
echo "$out/CodevisorNetFFI.xcframework"

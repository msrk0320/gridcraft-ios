#!/usr/bin/env bash
# Builds the Rust engine for iOS devices and packages it for Xcode:
#   ios/Generated/GridCraftFFI.xcframework  (static library + C header + module map)
#   ios/Generated/gridcraft_ffi.swift       (UniFFI Swift bindings)
# Runs on macOS (needs the iOS SDK from Xcode).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target=aarch64-apple-ios
lib="$root/rust/target/$target/release/libgridcraft_ffi.a"
gen="$root/build/gen"
headers="$root/build/headers"
out="$root/ios/Generated"

cd "$root/rust"
cargo build --release --lib --target "$target"
cargo run --release --features cli --bin uniffi-bindgen -- \
  generate --library "$lib" --language swift --out-dir "$gen"

rm -rf "$headers" "$out"
mkdir -p "$headers" "$out"
cp "$gen/gridcraft_ffiFFI.h" "$headers/"
cp "$gen/gridcraft_ffiFFI.modulemap" "$headers/module.modulemap"
cp "$gen/gridcraft_ffi.swift" "$out/"
xcodebuild -create-xcframework -library "$lib" -headers "$headers" -output "$out/GridCraftFFI.xcframework"

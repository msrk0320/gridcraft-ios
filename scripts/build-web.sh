#!/usr/bin/env bash
# Builds the mobile web app into build/web: the static files from web/www plus the engine
# compiled to WebAssembly (web/pkg via wasm-bindgen). Serve build/web with any static server.
# Needs: rustup target wasm32-unknown-unknown, and wasm-bindgen-cli at the version in web/rust/Cargo.lock.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/web"

cd "$root/web/rust"
cargo build --release --target wasm32-unknown-unknown
rm -rf "$out"
mkdir -p "$out"
cp -R "$root/web/www/." "$out/"
wasm-bindgen --target web --no-typescript --out-dir "$out/pkg" \
  target/wasm32-unknown-unknown/release/gridcraft_wasm.wasm
echo "Built $out"

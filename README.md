# GridCraft for iPhone and iPad

A native SwiftUI front end for [GridCraft](https://github.com/storytold/gridcraft), the open-source
Rust spreadsheet engine. The engine (formulas, recalculation, XLSX/CSV I/O) is used unchanged
through a small [UniFFI](https://mozilla.github.io/uniffi-rs/) bridge; only the UI is new.

## What works (MVP)

- Scrolling, virtualised grid with sticky row and column headers
- Tap to select, double-tap or use the formula bar to edit; Return enters and moves down
- Formulas with live recalculation (GridCraft's 500+ functions)
- Undo / redo, clear cell
- Open `.xlsx`, `.xls`, `.ods`, `.csv`, `.tsv`; export `.xlsx` and `.csv`
- Built-in samples (sales, budget, grades); sheet tabs

Not yet: cell formatting and colours, column widths from the file, charts, multi-cell selection,
copy/paste and hardware-keyboard navigation.

## Layout

| Path | What |
|---|---|
| `rust/` | `gridcraft-ffi`: wraps `gridcraft_engine::Session` for Swift. The engine is pinned by git rev in `rust/Cargo.toml`. |
| `ios/` | SwiftUI app. `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is generated. |
| `scripts/build-rust-ios.sh` | Builds the engine for `aarch64-apple-ios` and produces `ios/Generated/` (XCFramework + Swift bindings). |
| `.github/workflows/ios.yml` | Runs the Rust tests, then builds an unsigned `GridCraft.ipa` on a macOS runner. |

## Building without a Mac

1. Push to GitHub. The **iOS build** workflow runs on every push to `main`, or start it by hand under Actions.
2. Download the `GridCraft-ipa` artifact from the finished run and unzip it.
3. Install `GridCraft.ipa` on your phone with [Sideloadly](https://sideloadly.io) and a free Apple ID.
   Free signing lasts 7 days; re-sideload to refresh.

## Web app

The same engine compiled to WebAssembly, with a touch-friendly web front end in `web/www`.
It is deployed to GitHub Pages on every push to `main` by `.github/workflows/web.yml`:
**https://msrk0320.github.io/gridcraft-ios/**. Open it in Safari and use Share → Add to Home Screen
for a full-screen app that works offline. The open workbook is autosaved in that browser.

Build locally (needs the `wasm32-unknown-unknown` target and `wasm-bindgen-cli` at the version in
`web/rust/Cargo.lock`), then serve `build/web` with any static server:

```sh
bash scripts/build-web.sh
python -m http.server -d build/web
```

## Rust tests (any OS)

```sh
cd rust && cargo test
cd web/rust && cargo test
```

## Licence

MIT OR Apache-2.0, like GridCraft. The app icon is GridCraft's placeholder icon (same licence).

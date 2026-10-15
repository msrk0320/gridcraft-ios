//! wasm-bindgen bridge between the GridCraft engine and the mobile web app.
//!
//! Mirrors the iOS bridge in `rust/src/lib.rs`: one batch call per visible block of cells
//! (`viewport`), and everything else through the engine's command system.

use gridcraft_engine::core::{CellRef, MAX_COLS, MAX_ROWS};
use gridcraft_engine::{Session, display, io};
use serde_json::{Value as Json, json};
use wasm_bindgen::prelude::*;

/// Largest block `viewport` returns, so a bad request can't allocate millions of strings.
const MAX_VIEWPORT_ROWS: u32 = 400;
const MAX_VIEWPORT_COLS: u32 = 200;

fn err(e: impl std::fmt::Display) -> JsError {
    JsError::new(&e.to_string())
}

#[wasm_bindgen]
pub struct GridEngine {
    session: Session,
}

#[wasm_bindgen]
impl GridEngine {
    /// A session with one blank workbook.
    #[wasm_bindgen(constructor)]
    pub fn new() -> GridEngine {
        let mut session = Session::new();
        session.new_workbook();
        GridEngine { session }
    }

    #[wasm_bindgen(js_name = newWorkbook)]
    pub fn new_workbook(&mut self) {
        self.session = Session::new();
        self.session.new_workbook();
    }

    /// Replaces the open workbook with a built-in sample: `sales`, `budget` or `grades`.
    #[wasm_bindgen(js_name = openSample)]
    pub fn open_sample(&mut self, name: &str) -> Result<(), JsError> {
        let mut fresh = Session::new();
        fresh.execute_headless("file.new", json!({ "sample": name })).map_err(err)?;
        self.session = fresh;
        Ok(())
    }

    /// Opens a workbook from its file bytes; `name` (e.g. `book.xlsx`) picks the format.
    /// Returns import warnings. The current workbook is kept if opening fails.
    pub fn open(&mut self, name: &str, bytes: &[u8]) -> Result<Vec<String>, JsError> {
        let mut fresh = Session::new();
        let out = fresh.execute_headless("file.open", json!({ "name": name, "base64": io::base64_encode(bytes) })).map_err(err)?;
        if fresh.active().is_none() {
            return Err(err("the file didn't open a workbook"));
        }
        self.session = fresh;
        let warnings = out["warnings"].as_array().map(|w| w.iter().filter_map(|x| x.as_str().map(str::to_string)).collect());
        Ok(warnings.unwrap_or_default())
    }

    /// Encodes the workbook: `xlsx`, `csv`, `tsv`, `json` or `html`.
    pub fn save(&mut self, format: &str) -> Result<Vec<u8>, JsError> {
        let out = self.session.execute_headless("file.saveBytes", json!({ "format": format })).map_err(err)?;
        let b64 = out["base64"].as_str().ok_or_else(|| err("the engine returned no data"))?;
        io::base64_decode(b64).ok_or_else(|| err("the engine returned invalid data"))
    }

    pub fn title(&self) -> String {
        self.session.active().map(|d| d.title.clone()).unwrap_or_default()
    }

    #[wasm_bindgen(js_name = canUndo)]
    pub fn can_undo(&self) -> bool {
        self.session.active().is_some_and(|d| !d.undo.is_empty())
    }

    #[wasm_bindgen(js_name = canRedo)]
    pub fn can_redo(&self) -> bool {
        self.session.active().is_some_and(|d| !d.redo.is_empty())
    }

    /// Sheet names, in order.
    #[wasm_bindgen(js_name = sheetNames)]
    pub fn sheet_names(&self) -> Vec<String> {
        self.session.active().map(|d| d.wb.sheets.iter().map(|s| s.name.clone()).collect()).unwrap_or_default()
    }

    /// `[rows, cols]` up to the last used cell of the active sheet (`[0, 0]` when empty).
    #[wasm_bindgen(js_name = usedSize)]
    pub fn used_size(&self) -> Vec<u32> {
        let used = self.session.active().and_then(|d| d.wb.active()).and_then(|sh| sh.used_range());
        used.map_or(vec![0, 0], |r| vec![r.end.row + 1, r.end.col + 1])
    }

    #[wasm_bindgen(js_name = activeSheet)]
    pub fn active_sheet(&self) -> u32 {
        self.session.active().map_or(0, |d| d.wb.active_sheet as u32)
    }

    #[wasm_bindgen(js_name = activateSheet)]
    pub fn activate_sheet(&mut self, index: u32) -> Result<(), JsError> {
        self.session.execute_headless("sheet.activate", json!({ "sheet": index })).map_err(err)?;
        Ok(())
    }

    /// Display texts for a block of the active sheet, row-major, clamped to the sheet. The
    /// caller recomputes the clamped size the same way (`min(rows, MAX_ROWS - row0)`).
    pub fn viewport(&self, row0: u32, col0: u32, rows: u32, cols: u32) -> Vec<String> {
        let row0 = row0.min(MAX_ROWS - 1);
        let col0 = col0.min(MAX_COLS - 1);
        let rows = rows.min(MAX_VIEWPORT_ROWS).min(MAX_ROWS - row0);
        let cols = cols.min(MAX_VIEWPORT_COLS).min(MAX_COLS - col0);
        let mut texts = Vec::with_capacity((rows * cols) as usize);
        match self.session.active().and_then(|d| d.wb.active().map(|sh| (&d.wb, sh))) {
            Some((wb, sh)) => {
                for r in row0..row0 + rows {
                    for c in col0..col0 + cols {
                        texts.push(display::cell_text(wb, sh, CellRef::new(r, c)));
                    }
                }
            }
            None => texts.resize((rows * cols) as usize, String::new()),
        }
        texts
    }

    /// What the formula bar shows for a cell: its formula, or its value as typed.
    #[wasm_bindgen(js_name = editText)]
    pub fn edit_text(&self, row: u32, col: u32) -> String {
        match self.session.active().and_then(|d| d.wb.active().map(|sh| (&d.wb, sh))) {
            Some((wb, sh)) => display::edit_text(wb, sh, CellRef::new(row, col)),
            None => String::new(),
        }
    }

    /// Enters text, a number or a `=formula` into a cell of the active sheet (undoable).
    #[wasm_bindgen(js_name = setCell)]
    pub fn set_cell(&mut self, row: u32, col: u32, input: &str) -> Result<(), JsError> {
        let at = CellRef::new(row, col);
        if !at.is_valid() {
            return Err(err("cell is outside the sheet"));
        }
        self.session.execute_headless("cell.set", json!({ "cell": at.a1(), "input": input })).map_err(err)?;
        Ok(())
    }

    pub fn undo(&mut self) -> Result<(), JsError> {
        self.session.execute_headless("edit.undo", json!({})).map_err(err)?;
        Ok(())
    }

    pub fn redo(&mut self) -> Result<(), JsError> {
        self.session.execute_headless("edit.redo", json!({})).map_err(err)?;
        Ok(())
    }

    /// Escape hatch: runs any engine command with JSON parameters, returning its JSON result.
    pub fn execute(&mut self, command: &str, params_json: &str) -> Result<String, JsError> {
        let params: Json = if params_json.trim().is_empty() {
            Json::Null
        } else {
            serde_json::from_str(params_json).map_err(|e| err(format!("invalid JSON parameters: {e}")))?
        };
        Ok(self.session.execute_headless(command, params).map_err(err)?.to_string())
    }
}

impl Default for GridEngine {
    fn default() -> Self {
        GridEngine::new()
    }
}

// JsError can only be built on wasm, so these host tests only take paths that succeed.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;

    fn text(e: &GridEngine, row: u32, col: u32) -> String {
        e.viewport(row, col, 1, 1).remove(0)
    }

    #[test]
    fn edits_recalculate_and_undo() {
        let mut e = GridEngine::new();
        assert!(e.set_cell(0, 0, "4").is_ok());
        assert!(e.set_cell(1, 0, "=A1*10").is_ok());
        assert_eq!(text(&e, 1, 0), "40");
        assert_eq!(e.edit_text(1, 0), "=A1*10");
        assert!(e.undo().is_ok());
        assert_eq!(text(&e, 1, 0), "");
        assert_eq!(e.used_size(), vec![1, 1]);
    }

    #[test]
    fn xlsx_round_trip_and_samples() {
        let mut e = GridEngine::new();
        assert!(e.set_cell(2, 1, "=SUM(1,2)").is_ok());
        let bytes = e.save("xlsx").ok().unwrap_or_default();
        let mut f = GridEngine::new();
        assert!(f.open("b.xlsx", &bytes).is_ok());
        assert_eq!(text(&f, 2, 1), "3");
        assert!(f.open_sample("sales").is_ok());
        assert!(!f.sheet_names().is_empty());
    }

    #[test]
    fn viewport_is_clamped() {
        let e = GridEngine::new();
        assert_eq!(e.viewport(MAX_ROWS - 2, MAX_COLS - 1, 10, 10).len(), 2);
    }
}

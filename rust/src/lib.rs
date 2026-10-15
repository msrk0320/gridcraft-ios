//! UniFFI bridge between the GridCraft engine and the SwiftUI app.
//!
//! The surface is deliberately small and batch-shaped: the grid asks for a whole visible block
//! of cell texts in one call (`viewport`), and everything else goes through the engine's command
//! system (`execute`), the same entry point the desktop UI, CLI and MCP server use.

use std::sync::{Arc, Mutex, MutexGuard};

use gridcraft_engine::core::{CellRef, MAX_COLS, MAX_ROWS};
use gridcraft_engine::{Session, display, io};
use serde_json::{Value as Json, json};

uniffi::setup_scaffolding!();

/// Largest block `viewport` returns, so a bad request can't allocate millions of strings.
const MAX_VIEWPORT_ROWS: u32 = 400;
const MAX_VIEWPORT_COLS: u32 = 200;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum GridError {
    #[error("{msg}")]
    Failed { msg: String },
}

impl From<gridcraft_engine::EngineError> for GridError {
    fn from(e: gridcraft_engine::EngineError) -> Self {
        GridError::Failed { msg: e.to_string() }
    }
}

fn fail(msg: impl Into<String>) -> GridError {
    GridError::Failed { msg: msg.into() }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SheetInfo {
    pub name: String,
    /// Rows and columns up to the last used cell (0 for an empty sheet).
    pub used_rows: u32,
    pub used_cols: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Viewport {
    pub row0: u32,
    pub col0: u32,
    pub rows: u32,
    pub cols: u32,
    /// Display text of each cell, row-major (`rows * cols` entries).
    pub texts: Vec<String>,
}

#[derive(uniffi::Object)]
pub struct GridEngine {
    session: Mutex<Session>,
}

impl GridEngine {
    fn lock(&self) -> MutexGuard<'_, Session> {
        // A panic while holding the lock leaves the session usable: commands restore the workbook.
        self.session.lock().unwrap_or_else(|p| p.into_inner())
    }
}

#[uniffi::export]
impl GridEngine {
    /// A session with one blank workbook.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let mut s = Session::new();
        s.new_workbook();
        Arc::new(GridEngine { session: Mutex::new(s) })
    }

    /// Replaces the open workbook with a blank one.
    pub fn new_workbook(&self) {
        let mut s = self.lock();
        *s = Session::new();
        s.new_workbook();
    }

    /// Replaces the open workbook with a built-in sample: `sales`, `budget` or `grades`.
    pub fn open_sample(&self, name: String) -> Result<(), GridError> {
        let mut fresh = Session::new();
        fresh.execute_headless("file.new", json!({ "sample": name }))?;
        *self.lock() = fresh;
        Ok(())
    }

    /// Opens a workbook from its file bytes; `name` (e.g. `book.xlsx`) picks the format.
    /// Returns import warnings to show the user. The current workbook is kept if opening fails.
    pub fn open(&self, name: String, bytes: Vec<u8>) -> Result<Vec<String>, GridError> {
        let mut fresh = Session::new();
        let out = fresh.execute_headless("file.open", json!({ "name": name, "base64": io::base64_encode(&bytes) }))?;
        if fresh.active().is_none() {
            return Err(fail("the file didn't open a workbook"));
        }
        *self.lock() = fresh;
        let warnings = out["warnings"].as_array().map(|w| w.iter().filter_map(|x| x.as_str().map(str::to_string)).collect());
        Ok(warnings.unwrap_or_default())
    }

    /// Encodes the workbook: `xlsx`, `csv`, `tsv`, `json` or `html`.
    pub fn save(&self, format: String) -> Result<Vec<u8>, GridError> {
        let out = self.lock().execute_headless("file.saveBytes", json!({ "format": format }))?;
        let b64 = out["base64"].as_str().ok_or_else(|| fail("the engine returned no data"))?;
        io::base64_decode(b64).ok_or_else(|| fail("the engine returned invalid data"))
    }

    pub fn title(&self) -> String {
        self.lock().active().map(|d| d.title.clone()).unwrap_or_default()
    }

    /// Bumps every time the workbook changes; the UI refetches when it moves.
    pub fn revision(&self) -> u64 {
        self.lock().active().map(|d| d.revision).unwrap_or(0)
    }

    pub fn can_undo(&self) -> bool {
        self.lock().active().is_some_and(|d| !d.undo.is_empty())
    }

    pub fn can_redo(&self) -> bool {
        self.lock().active().is_some_and(|d| !d.redo.is_empty())
    }

    pub fn sheets(&self) -> Vec<SheetInfo> {
        let s = self.lock();
        let Some(d) = s.active() else { return vec![] };
        d.wb.sheets
            .iter()
            .map(|sh| {
                let (used_rows, used_cols) = sh.used_range().map_or((0, 0), |r| (r.end.row + 1, r.end.col + 1));
                SheetInfo { name: sh.name.clone(), used_rows, used_cols }
            })
            .collect()
    }

    pub fn active_sheet(&self) -> u32 {
        self.lock().active().map_or(0, |d| d.wb.active_sheet as u32)
    }

    pub fn activate_sheet(&self, index: u32) -> Result<(), GridError> {
        self.lock().execute_headless("sheet.activate", json!({ "sheet": index }))?;
        Ok(())
    }

    /// Display texts for a block of the active sheet, clamped to the sheet and to a sane size.
    pub fn viewport(&self, row0: u32, col0: u32, rows: u32, cols: u32) -> Viewport {
        let row0 = row0.min(MAX_ROWS - 1);
        let col0 = col0.min(MAX_COLS - 1);
        let rows = rows.min(MAX_VIEWPORT_ROWS).min(MAX_ROWS - row0);
        let cols = cols.min(MAX_VIEWPORT_COLS).min(MAX_COLS - col0);
        let s = self.lock();
        let mut texts = Vec::with_capacity((rows * cols) as usize);
        match s.active().and_then(|d| d.wb.active().map(|sh| (&d.wb, sh))) {
            Some((wb, sh)) => {
                for r in row0..row0 + rows {
                    for c in col0..col0 + cols {
                        texts.push(display::cell_text(wb, sh, CellRef::new(r, c)));
                    }
                }
            }
            None => texts.resize((rows * cols) as usize, String::new()),
        }
        Viewport { row0, col0, rows, cols, texts }
    }

    /// What the formula bar shows for a cell: its formula, or its value as typed.
    pub fn edit_text(&self, row: u32, col: u32) -> String {
        let s = self.lock();
        match s.active().and_then(|d| d.wb.active().map(|sh| (&d.wb, sh))) {
            Some((wb, sh)) => display::edit_text(wb, sh, CellRef::new(row, col)),
            None => String::new(),
        }
    }

    /// Enters text, a number or a `=formula` into a cell of the active sheet (undoable).
    pub fn set_cell(&self, row: u32, col: u32, input: String) -> Result<(), GridError> {
        let at = CellRef::new(row, col);
        if !at.is_valid() {
            return Err(fail("cell is outside the sheet"));
        }
        self.lock().execute_headless("cell.set", json!({ "cell": at.a1(), "input": input }))?;
        Ok(())
    }

    pub fn undo(&self) -> Result<(), GridError> {
        self.lock().execute_headless("edit.undo", json!({}))?;
        Ok(())
    }

    pub fn redo(&self) -> Result<(), GridError> {
        self.lock().execute_headless("edit.redo", json!({}))?;
        Ok(())
    }

    /// Column width and row height of the active sheet, in the engine's pixel units.
    pub fn col_width(&self, col: u32) -> f32 {
        self.lock().active().and_then(|d| d.wb.active().map(|sh| sh.col_width(col))).unwrap_or(64.0)
    }

    pub fn row_height(&self, row: u32) -> f32 {
        self.lock().active().and_then(|d| d.wb.active().map(|sh| sh.row_height(row))).unwrap_or(20.0)
    }

    /// Escape hatch: runs any engine command (`home.bold`, `data.sortAscending`…) with JSON
    /// parameters and returns its JSON result.
    pub fn execute(&self, command: String, params_json: String) -> Result<String, GridError> {
        let params: Json = if params_json.trim().is_empty() {
            Json::Null
        } else {
            serde_json::from_str(&params_json).map_err(|e| fail(format!("invalid JSON parameters: {e}")))?
        };
        let out = self.lock().execute_headless(&command, params)?;
        Ok(out.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(e: &GridEngine, row: u32, col: u32) -> String {
        e.viewport(row, col, 1, 1).texts.remove(0)
    }

    #[test]
    fn formulas_recalculate_after_edits() {
        let e = GridEngine::new();
        e.set_cell(0, 0, "2".into()).unwrap();
        e.set_cell(1, 0, "3".into()).unwrap();
        e.set_cell(2, 0, "=A1*A2".into()).unwrap();
        assert_eq!(text(&e, 2, 0), "6");
        assert_eq!(e.edit_text(2, 0), "=A1*A2");
        e.set_cell(0, 0, "10".into()).unwrap();
        assert_eq!(text(&e, 2, 0), "30");
    }

    #[test]
    fn undo_and_redo_restore_values() {
        let e = GridEngine::new();
        let rev = e.revision();
        e.set_cell(0, 0, "hello".into()).unwrap();
        assert!(e.revision() > rev);
        assert!(e.can_undo());
        e.undo().unwrap();
        assert_eq!(text(&e, 0, 0), "");
        e.redo().unwrap();
        assert_eq!(text(&e, 0, 0), "hello");
    }

    #[test]
    fn xlsx_round_trips_through_bytes() {
        let e = GridEngine::new();
        e.set_cell(0, 0, "Name".into()).unwrap();
        e.set_cell(0, 1, "=1+1".into()).unwrap();
        let bytes = e.save("xlsx".into()).unwrap();
        assert!(bytes.starts_with(b"PK"), "xlsx is a zip");

        let f = GridEngine::new();
        f.open("book.xlsx".into(), bytes).unwrap();
        assert_eq!(text(&f, 0, 0), "Name");
        assert_eq!(text(&f, 0, 1), "2");
        assert_eq!(f.edit_text(0, 1), "=1+1");
    }

    #[test]
    fn csv_opens() {
        let e = GridEngine::new();
        e.open("data.csv".into(), b"a,b\n1,2\n".to_vec()).unwrap();
        assert_eq!(text(&e, 1, 1), "2");
        assert_eq!(e.sheets()[0].used_rows, 2);
        assert_eq!(e.sheets()[0].used_cols, 2);
    }

    #[test]
    fn bad_file_keeps_current_workbook() {
        let e = GridEngine::new();
        e.set_cell(0, 0, "keep".into()).unwrap();
        // A zip signature with nothing valid behind it.
        let broken = [b"PK".as_slice(), &[0u8; 64]].concat();
        assert!(e.open("broken.xlsx".into(), broken).is_err());
        assert_eq!(text(&e, 0, 0), "keep");
    }

    #[test]
    fn samples_and_sheets() {
        let e = GridEngine::new();
        e.open_sample("sales".into()).unwrap();
        let sheets = e.sheets();
        assert!(!sheets.is_empty());
        assert!(sheets[e.active_sheet() as usize].used_rows > 0);
        assert!(e.open_sample("nope".into()).is_err());
    }

    #[test]
    fn viewport_is_clamped() {
        let e = GridEngine::new();
        let v = e.viewport(MAX_ROWS - 2, MAX_COLS - 1, 10, 10);
        assert_eq!((v.rows, v.cols), (2, 1));
        assert_eq!(v.texts.len(), 2);
        let v = e.viewport(0, 0, 100_000, 100_000);
        assert_eq!(v.texts.len(), (MAX_VIEWPORT_ROWS * MAX_VIEWPORT_COLS) as usize);
    }

    #[test]
    fn execute_runs_engine_commands() {
        let e = GridEngine::new();
        e.execute("cell.set".into(), r#"{"cell":"C3","input":"=SUM(1,2,3)"}"#.into()).unwrap();
        assert_eq!(text(&e, 2, 2), "6");
        assert!(e.execute("no.such".into(), "".into()).is_err());
        assert!(e.execute("cell.set".into(), "{bad".into()).is_err());
        assert!(e.set_cell(MAX_ROWS, 0, "x".into()).is_err());
    }
}

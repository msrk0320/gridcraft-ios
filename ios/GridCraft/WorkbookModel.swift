import Foundation
import UniformTypeIdentifiers

/// Owns the Rust engine and the UI state around it (selection, sheets, errors).
@MainActor
final class WorkbookModel: ObservableObject {
    let engine = GridEngine()

    /// Bumped after every change so views redraw; the engine's own revision restarts per workbook.
    @Published private(set) var version = 0
    @Published private(set) var selectedRow: UInt32 = 0
    @Published private(set) var selectedCol: UInt32 = 0
    @Published private(set) var sheets: [SheetInfo] = []
    @Published private(set) var activeSheet = 0
    @Published private(set) var title = ""
    @Published var errorMessage: String?

    init() {
        refresh()
    }

    var selectionName: String { Self.columnName(selectedCol) + String(selectedRow + 1) }
    var editText: String { engine.editText(row: selectedRow, col: selectedCol) }
    var canUndo: Bool { engine.canUndo() }
    var canRedo: Bool { engine.canRedo() }

    func select(row: UInt32, col: UInt32) {
        selectedRow = row
        selectedCol = col
    }

    func move(rows: Int, cols: Int) {
        let r = max(0, Int(selectedRow) + rows)
        let c = max(0, Int(selectedCol) + cols)
        select(row: UInt32(r), col: UInt32(c))
    }

    /// Enters text, a number or a `=formula` into the selected cell.
    func commit(_ input: String) {
        run { try engine.setCell(row: selectedRow, col: selectedCol, input: input) }
    }

    func clearSelection() { commit("") }
    func undo() { run { try engine.undo() } }
    func redo() { run { try engine.redo() } }

    func newWorkbook() {
        engine.newWorkbook()
        select(row: 0, col: 0)
        refresh()
    }

    func openSample(_ name: String) {
        run { try engine.openSample(name: name) }
        select(row: 0, col: 0)
    }

    func activate(sheet index: Int) {
        run { try engine.activateSheet(index: UInt32(index)) }
        select(row: 0, col: 0)
    }

    func open(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let warnings = try engine.open(name: url.lastPathComponent, bytes: data)
            select(row: 0, col: 0)
            if !warnings.isEmpty { errorMessage = warnings.prefix(5).joined(separator: "\n\n") }
        } catch {
            errorMessage = Self.describe(error)
        }
        refresh()
    }

    func export(format: ExportFormat) -> SpreadsheetFile? {
        do {
            return SpreadsheetFile(data: try engine.save(format: format.rawValue), type: format.type)
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    var exportName: String {
        let base = (title as NSString).deletingPathExtension
        return base.isEmpty ? "Book" : base
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = Self.describe(error) }
        refresh()
    }

    func refresh() {
        sheets = engine.sheets()
        activeSheet = Int(engine.activeSheet())
        title = engine.title()
        version += 1
    }

    static func describe(_ error: Error) -> String {
        if case let GridError.Failed(msg) = error { return msg }
        return error.localizedDescription
    }

    /// 0 → A, 25 → Z, 26 → AA.
    static func columnName(_ col: UInt32) -> String {
        var n = Int(col) + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case xlsx, csv

    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .xlsx: UTType(filenameExtension: "xlsx") ?? .data
        case .csv: .commaSeparatedText
        }
    }
}

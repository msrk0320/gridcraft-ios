import SwiftUI
import UIKit

enum GridMetrics {
    static let cellWidth: CGFloat = 96
    static let cellHeight: CGFloat = 34
    static let headerWidth: CGFloat = 48
    static let headerHeight: CGFloat = 28
    static let maxRows = 1_048_576
    static let maxCols = 16_384
}

/// A virtualised spreadsheet grid: a scroll view whose canvas covers only the visible area and
/// redraws just the cells in it, fetched from the engine in one call per frame.
final class SpreadsheetScrollView: UIScrollView, UIScrollViewDelegate {
    var fetch: ((UInt32, UInt32, UInt32, UInt32) -> Viewport)?
    var onSelect: ((UInt32, UInt32) -> Void)?
    var onEdit: (() -> Void)?
    private(set) var selectedRow: UInt32 = 0
    private(set) var selectedCol: UInt32 = 0

    private let canvas = GridCanvas()
    private var rowCount = 0
    private var colCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .systemBackground
        isDirectionalLockEnabled = true
        canvas.grid = self
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = .systemBackground
        canvas.contentMode = .redraw
        addSubview(canvas)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Makes room for the used range plus space to grow. Never shrinks while scrolling.
    func ensureSize(rows: Int, cols: Int) {
        let r = min(max(rows, rowCount), GridMetrics.maxRows)
        let c = min(max(cols, colCount), GridMetrics.maxCols)
        guard r != rowCount || c != colCount else { return }
        rowCount = r
        colCount = c
        contentSize = CGSize(
            width: GridMetrics.headerWidth + CGFloat(c) * GridMetrics.cellWidth,
            height: GridMetrics.headerHeight + CGFloat(r) * GridMetrics.cellHeight
        )
    }

    /// Resets the scrollable area for a different workbook or sheet.
    func resetSize(rows: Int, cols: Int) {
        rowCount = 0
        colCount = 0
        ensureSize(rows: rows, cols: cols)
        contentOffset = .zero
    }

    func setSelection(row: UInt32, col: UInt32) {
        guard row != selectedRow || col != selectedCol else { return }
        selectedRow = row
        selectedCol = col
        ensureSize(rows: Int(row) + 50, cols: Int(col) + 10)
        scrollToSelection()
        redraw()
    }

    func redraw() {
        canvas.setNeedsDisplay()
    }

    func cellRect(row: UInt32, col: UInt32) -> CGRect {
        CGRect(
            x: GridMetrics.headerWidth + CGFloat(col) * GridMetrics.cellWidth,
            y: GridMetrics.headerHeight + CGFloat(row) * GridMetrics.cellHeight,
            width: GridMetrics.cellWidth,
            height: GridMetrics.cellHeight
        )
    }

    private func scrollToSelection() {
        // Leave room for the sticky headers that cover the top and left edges.
        var rect = cellRect(row: selectedRow, col: selectedCol)
        rect.origin.x -= GridMetrics.headerWidth
        rect.size.width += GridMetrics.headerWidth
        rect.origin.y -= GridMetrics.headerHeight
        rect.size.height += GridMetrics.headerHeight
        scrollRectToVisible(rect, animated: true)
    }

    /// The cell under a point in content coordinates; nil on the headers.
    private func hitCell(at p: CGPoint) -> (row: UInt32, col: UInt32)? {
        guard p.x - contentOffset.x >= GridMetrics.headerWidth, p.y - contentOffset.y >= GridMetrics.headerHeight else {
            return nil
        }
        let c = Int((p.x - GridMetrics.headerWidth) / GridMetrics.cellWidth)
        let r = Int((p.y - GridMetrics.headerHeight) / GridMetrics.cellHeight)
        guard r >= 0, c >= 0, r < GridMetrics.maxRows, c < GridMetrics.maxCols else { return nil }
        return (UInt32(r), UInt32(c))
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let hit = hitCell(at: g.location(in: self)) else { return }
        onSelect?(hit.row, hit.col)
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let hit = hitCell(at: g.location(in: self)) else { return }
        onSelect?(hit.row, hit.col)
        onEdit?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // bounds.origin is the scroll offset, so the canvas always covers exactly the visible area.
        canvas.frame = bounds
        redraw()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // An endless sheet: add rows and columns as the user nears the edge.
        let nearBottom = contentOffset.y + 2 * bounds.height > contentSize.height
        let nearRight = contentOffset.x + 2 * bounds.width > contentSize.width
        if nearBottom || nearRight {
            ensureSize(rows: rowCount + (nearBottom ? 500 : 0), cols: colCount + (nearRight ? 26 : 0))
        }
    }
}

/// Draws the visible cells, grid lines, selection and sticky row/column headers.
final class GridCanvas: UIView {
    weak var grid: SpreadsheetScrollView?

    private let cellFont = UIFont.systemFont(ofSize: 15)
    private let headerFont = UIFont.systemFont(ofSize: 12, weight: .medium)

    override func draw(_ rect: CGRect) {
        guard let grid, let ctx = UIGraphicsGetCurrentContext() else { return }
        let cw = GridMetrics.cellWidth
        let ch = GridMetrics.cellHeight
        let hw = GridMetrics.headerWidth
        let hh = GridMetrics.headerHeight
        // Clamp so rubber-band bouncing past the edges doesn't ask for negative cells.
        let off = CGPoint(x: max(0, grid.contentOffset.x), y: max(0, grid.contentOffset.y))
        let firstCol = min(Int(off.x / cw), GridMetrics.maxCols - 1)
        let firstRow = min(Int(off.y / ch), GridMetrics.maxRows - 1)
        let cols = Int(ceil(bounds.width / cw)) + 1
        let rows = Int(ceil(bounds.height / ch)) + 1
        let x0 = hw + CGFloat(firstCol) * cw - off.x
        let y0 = hh + CGFloat(firstRow) * ch - off.y

        // Cell texts.
        if let vp = grid.fetch?(UInt32(firstRow), UInt32(firstCol), UInt32(rows), UInt32(cols)) {
            let n = Int(vp.cols)
            for i in 0..<Int(vp.rows) {
                for j in 0..<n {
                    let text = vp.texts[i * n + j]
                    if text.isEmpty { continue }
                    let cell = CGRect(x: x0 + CGFloat(j) * cw, y: y0 + CGFloat(i) * ch, width: cw, height: ch)
                    drawText(text, in: cell.insetBy(dx: 6, dy: 0), font: cellFont, color: .label,
                             alignment: Self.looksNumeric(text) ? .right : .left)
                }
            }
        }

        // Grid lines.
        ctx.setStrokeColor(UIColor.separator.cgColor)
        ctx.setLineWidth(1 / max(1, traitCollection.displayScale))
        for j in 0...cols {
            let x = x0 + CGFloat(j) * cw
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        for i in 0...rows {
            let y = y0 + CGFloat(i) * ch
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        ctx.strokePath()

        // Selected cell.
        let sel = grid.cellRect(row: grid.selectedRow, col: grid.selectedCol).offsetBy(dx: -off.x, dy: -off.y)
        ctx.setStrokeColor(UIColor.systemGreen.cgColor)
        ctx.setLineWidth(2.5)
        ctx.stroke(sel.insetBy(dx: 1, dy: 1))

        // Sticky headers, drawn last so they cover the cells scrolling under them.
        let headerFill = UIColor.secondarySystemBackground
        let highlight = UIColor.systemGreen.withAlphaComponent(0.25)
        headerFill.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: hh))
        ctx.fill(CGRect(x: 0, y: 0, width: hw, height: bounds.height))
        for j in 0..<cols {
            let col = firstCol + j
            guard col < GridMetrics.maxCols else { break }
            let r = CGRect(x: x0 + CGFloat(j) * cw, y: 0, width: cw, height: hh)
            if r.maxX <= hw { continue }
            if col == Int(grid.selectedCol) {
                highlight.setFill()
                ctx.fill(r)
            }
            drawText(WorkbookModel.columnName(UInt32(col)), in: r, font: headerFont, color: .secondaryLabel, alignment: .center)
        }
        for i in 0..<rows {
            let row = firstRow + i
            guard row < GridMetrics.maxRows else { break }
            let r = CGRect(x: 0, y: y0 + CGFloat(i) * ch, width: hw, height: ch)
            if r.maxY <= hh { continue }
            if row == Int(grid.selectedRow) {
                highlight.setFill()
                ctx.fill(r)
            }
            drawText(String(row + 1), in: r, font: headerFont, color: .secondaryLabel, alignment: .center)
        }
        // Corner box and header borders.
        headerFill.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh))
        ctx.setStrokeColor(UIColor.separator.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: hh))
        ctx.addLine(to: CGPoint(x: bounds.width, y: hh))
        ctx.move(to: CGPoint(x: hw, y: 0))
        ctx.addLine(to: CGPoint(x: hw, y: bounds.height))
        ctx.strokePath()
    }

    private func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let h = font.lineHeight
        let line = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        (text as NSString).draw(in: line, withAttributes: attrs)
    }

    /// Numbers, currency and percentages align right, like Excel's General alignment.
    static func looksNumeric(_ text: String) -> Bool {
        let stripped = text.filter { !" ,$%€£¥()".contains($0) }
        return !stripped.isEmpty && Double(stripped) != nil
    }
}

struct SpreadsheetGrid: UIViewRepresentable {
    @ObservedObject var model: WorkbookModel
    var onEdit: () -> Void

    final class Coordinator {
        var sheetKey = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SpreadsheetScrollView {
        let view = SpreadsheetScrollView(frame: .zero)
        let engine = model.engine
        let workbook = model
        view.fetch = { engine.viewport(row0: $0, col0: $1, rows: $2, cols: $3) }
        view.onSelect = { [weak workbook] r, c in workbook?.select(row: r, col: c) }
        return view
    }

    func updateUIView(_ view: SpreadsheetScrollView, context: Context) {
        view.onEdit = onEdit
        let sheet = model.sheets.indices.contains(model.activeSheet) ? model.sheets[model.activeSheet] : nil
        let rows = Int(sheet?.usedRows ?? 0) + 200
        let cols = Int(sheet?.usedCols ?? 0) + 26
        // A different workbook or sheet starts from the top-left with a fresh scroll area.
        let key = "\(model.title)|\(model.activeSheet)|\(sheet?.name ?? "")"
        if key != context.coordinator.sheetKey {
            context.coordinator.sheetKey = key
            view.resetSize(rows: rows, cols: cols)
        } else {
            view.ensureSize(rows: rows, cols: cols)
        }
        view.setSelection(row: model.selectedRow, col: model.selectedCol)
        view.redraw()
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = WorkbookModel()
    @State private var draft = ""
    @FocusState private var editing: Bool
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile: SpreadsheetFile?

    private static let openTypes: [UTType] = [
        .spreadsheet, UTType(filenameExtension: "xlsx") ?? .data, .commaSeparatedText, .tabSeparatedText, .plainText,
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                formulaBar
                Divider()
                SpreadsheetGrid(model: model, onEdit: { editing = true })
                    .ignoresSafeArea(.container, edges: .bottom)
                Divider()
                sheetTabs
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .onChange(of: "\(model.selectedRow):\(model.selectedCol):\(model.version)", initial: true) {
            draft = model.editText
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.openTypes) { result in
            switch result {
            case let .success(url): model.open(url: url)
            case let .failure(error): model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportFile?.type ?? .data,
                      defaultFilename: model.exportName) { result in
            if case let .failure(error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("GridCraft", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var formulaBar: some View {
        HStack(spacing: 8) {
            Text(model.selectionName)
                .font(.system(.subheadline, design: .monospaced))
                .frame(minWidth: 56)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            Text("fx").font(.subheadline.italic()).foregroundStyle(.secondary)
            TextField("Value or =formula", text: $draft)
                .focused($editing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.default)
                .submitLabel(.next)
                .onSubmit {
                    model.commit(draft)
                    model.move(rows: 1, cols: 0)
                    editing = true
                }
            if editing {
                Button { draft = model.editText; editing = false } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
                Button { model.commit(draft); editing = false } label: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sheetTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.sheets.enumerated()), id: \.offset) { index, sheet in
                    Button(sheet.name) { model.activate(sheet: index) }
                        .font(.subheadline.weight(index == model.activeSheet ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(index == model.activeSheet ? Color.green.opacity(0.2) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(index == model.activeSheet ? Color.primary : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("New Workbook", systemImage: "doc") { model.newWorkbook() }
                Button("Open…", systemImage: "folder") { importing = true }
                Menu("Open Sample", systemImage: "doc.text.magnifyingglass") {
                    Button("Quarterly Sales") { model.openSample("sales") }
                    Button("Household Budget") { model.openSample("budget") }
                    Button("Gradebook") { model.openSample("grades") }
                }
                Divider()
                ForEach(ExportFormat.allCases) { format in
                    Button("Export as \(format.rawValue.uppercased())…", systemImage: "square.and.arrow.up") {
                        exportFile = model.export(format: format)
                        exporting = exportFile != nil
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.clearSelection() } label: { Image(systemName: "eraser") }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
        }
    }
}

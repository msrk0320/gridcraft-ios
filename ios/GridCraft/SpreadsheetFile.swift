import SwiftUI
import UniformTypeIdentifiers

/// Encoded workbook bytes handed to the system's Save sheet.
struct SpreadsheetFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] {
        [UTType(filenameExtension: "xlsx") ?? .data, .commaSeparatedText]
    }

    var data: Data
    var type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

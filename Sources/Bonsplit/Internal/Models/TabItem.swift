import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Custom UTType for tab drag and drop payloads.
///
/// Conforms to `public.data` so the Codable-encoded `TabTransferData`
/// can ride on any data-typed pasteboard item. The identifier must be
/// declared as a `UTExportedTypeDeclarations` entry in the embedding
/// app's `Info.plist`, otherwise AppKit silently drops the type.
///
/// Default identifier is reverse-DNS under Smart-Byte's `bonsplit`
/// namespace. If you embed Bonsplit in your own app and prefer a
/// different identifier, change the string below and update your
/// `Info.plist` accordingly.
extension UTType {
    static var tabTransfer: UTType {
        UTType(exportedAs: "com.smartbyte.bonsplit.tabtransfer", conformingTo: .data)
    }
}

/// Represents a single tab in a pane's tab bar (internal representation)
struct TabItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var icon: String?
    var isDirty: Bool

    init(
        id: UUID = UUID(),
        title: String,
        icon: String? = "doc.text",
        isDirty: Bool = false
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isDirty = isDirty
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Transferable for Drag & Drop

extension TabItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tabTransfer)
    }
}

/// Transfer data that includes source pane information for cross-pane moves
struct TabTransferData: Codable, Transferable {
    let tab: TabItem
    let sourcePaneId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tabTransfer)
    }
}

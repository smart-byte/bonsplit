import Foundation

/// Opaque identifier for panes
public struct PaneID: Hashable, Codable, Sendable {
    public let id: UUID

    public init() {
        id = UUID()
    }

    init(id: UUID) {
        self.id = id
    }
}

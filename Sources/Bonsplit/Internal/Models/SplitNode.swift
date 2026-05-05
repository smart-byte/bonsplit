import Foundation

/// Represents a pane with its computed bounds in normalized coordinates (0-1)
struct PaneBounds {
    let paneId: PaneID
    let bounds: CGRect
}

/// Recursive structure representing the split tree
/// - pane: A leaf node containing a single pane with tabs
/// - split: A branch node containing two children with a divider
indirect enum SplitNode: Identifiable, Equatable {
    case pane(PaneState)
    case split(SplitState)

    var id: UUID {
        switch self {
        case let .pane(state):
            state.id.id
        case let .split(state):
            state.id
        }
    }

    /// Find a pane by its ID
    func findPane(_ paneId: PaneID) -> PaneState? {
        switch self {
        case let .pane(state):
            state.id == paneId ? state : nil
        case let .split(state):
            state.first.findPane(paneId) ?? state.second.findPane(paneId)
        }
    }

    /// Get all pane IDs in the tree
    var allPaneIds: [PaneID] {
        switch self {
        case let .pane(state):
            [state.id]
        case let .split(state):
            state.first.allPaneIds + state.second.allPaneIds
        }
    }

    /// Get all panes in the tree
    var allPanes: [PaneState] {
        switch self {
        case let .pane(state):
            [state]
        case let .split(state):
            state.first.allPanes + state.second.allPanes
        }
    }

    static func == (lhs: SplitNode, rhs: SplitNode) -> Bool {
        lhs.id == rhs.id
    }

    /// Compute normalized bounds (0-1) for all panes in the tree
    /// - Parameter availableRect: The rect available for this subtree (starts as unit rect)
    /// - Returns: Array of pane IDs with their computed bounds
    func computePaneBounds(in availableRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [PaneBounds] {
        switch self {
        case let .pane(paneState):
            return [PaneBounds(paneId: paneState.id, bounds: availableRect)]

        case let .split(splitState):
            let dividerPos = splitState.dividerPosition
            let firstRect: CGRect
            let secondRect: CGRect

            switch splitState.orientation {
            case .horizontal: // Side-by-side: first=LEFT, second=RIGHT
                firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                                   width: availableRect.width * dividerPos, height: availableRect.height)
                secondRect = CGRect(x: availableRect.minX + availableRect.width * dividerPos, y: availableRect.minY,
                                    width: availableRect.width * (1 - dividerPos), height: availableRect.height)
            case .vertical: // Stacked: first=TOP, second=BOTTOM
                firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                                   width: availableRect.width, height: availableRect.height * dividerPos)
                secondRect = CGRect(x: availableRect.minX, y: availableRect.minY + availableRect.height * dividerPos,
                                    width: availableRect.width, height: availableRect.height * (1 - dividerPos))
            }

            return splitState.first.computePaneBounds(in: firstRect)
                + splitState.second.computePaneBounds(in: secondRect)
        }
    }
}

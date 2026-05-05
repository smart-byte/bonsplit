import Foundation

/// Protocol for receiving callbacks about tab bar events
@MainActor
public protocol BonsplitDelegate: AnyObject {
    // MARK: - Tab Lifecycle (Veto Operations)

    /// Called when a new tab is about to be created.
    /// Return `false` to prevent creation.
    func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Tab, inPane pane: PaneID) -> Bool

    /// Called when a tab is about to be closed.
    /// Return `false` to prevent closing (e.g., prompt to save unsaved changes).
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Tab, inPane pane: PaneID) -> Bool

    // MARK: - Tab Lifecycle (Notifications)

    /// Called after a tab has been created.
    func splitTabBar(_ controller: BonsplitController, didCreateTab tab: Tab, inPane pane: PaneID)

    /// Called after a tab has been closed.
    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID)

    /// Called when a tab is selected.
    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Tab, inPane pane: PaneID)

    /// Called when a tab is moved between panes.
    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Tab, fromPane source: PaneID, toPane destination: PaneID)

    // MARK: - Split Lifecycle (Veto Operations)

    /// Called when a split is about to be created.
    /// Return `false` to prevent the split.
    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool

    /// Called when a pane is about to be closed.
    /// Return `false` to prevent closing.
    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool

    // MARK: - Split Lifecycle (Notifications)

    /// Called after a split has been created.
    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation)

    /// Called after a pane has been closed.
    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID)

    // MARK: - Focus

    /// Called when focus changes to a different pane.
    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID)

    // MARK: - Geometry

    /// Called when any pane geometry changes (resize, split, close)
    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot)

    /// Called to check if notifications should be sent during divider drag (opt-in for real-time sync)
    func splitTabBar(_ controller: BonsplitController, shouldNotifyDuringDrag: Bool) -> Bool
}

// MARK: - Default Implementations (all methods optional)

public extension BonsplitDelegate {
    func splitTabBar(_: BonsplitController, shouldCreateTab _: Tab, inPane _: PaneID) -> Bool {
        true
    }

    func splitTabBar(_: BonsplitController, shouldCloseTab _: Tab, inPane _: PaneID) -> Bool {
        true
    }

    func splitTabBar(_: BonsplitController, didCreateTab _: Tab, inPane _: PaneID) {}
    func splitTabBar(_: BonsplitController, didCloseTab _: TabID, fromPane _: PaneID) {}
    func splitTabBar(_: BonsplitController, didSelectTab _: Tab, inPane _: PaneID) {}
    func splitTabBar(_: BonsplitController, didMoveTab _: Tab, fromPane _: PaneID, toPane _: PaneID) {}
    func splitTabBar(_: BonsplitController, shouldSplitPane _: PaneID, orientation _: SplitOrientation) -> Bool {
        true
    }

    func splitTabBar(_: BonsplitController, shouldClosePane _: PaneID) -> Bool {
        true
    }

    func splitTabBar(_: BonsplitController, didSplitPane _: PaneID, newPane _: PaneID, orientation _: SplitOrientation) {}
    func splitTabBar(_: BonsplitController, didClosePane _: PaneID) {}
    func splitTabBar(_: BonsplitController, didFocusPane _: PaneID) {}
    func splitTabBar(_: BonsplitController, didChangeGeometry _: LayoutSnapshot) {}
    func splitTabBar(_: BonsplitController, shouldNotifyDuringDrag _: Bool) -> Bool {
        false
    }
}

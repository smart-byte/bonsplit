# Changelog

All notable changes to this fork will be documented in this file.
Releases prior to `0.1.0` are upstream `almonk/bonsplit` versions and
listed here for reference only — the Smart-Byte fork starts its own
version line at `0.1.0`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-05-06

### Fixed

- Tab single-click no longer accidentally starts a drag. The previous `NSPanGestureRecognizer` fired on the first `mouseDragged`, which on macOS happens at sub-pixel jitter — meaning a normal "click to select a tab" with even 1pt of mouse movement was misinterpreted as a drag, and SwiftUI's `.onTapGesture` never saw the click. Replaced with a custom `TabDragGestureRecognizer` that only transitions to `.began` after the cursor moves more than 3pt from the mouse-down location. Plain clicks (no movement / minor jitter) flow through to the SwiftUI host normally and trigger tab selection / close-button taps as expected.

## [0.1.0] - 2026-05-05 — Smart-Byte fork initial release

Forked from upstream `1.1.1`. First Smart-Byte release with the patches
applied that Voilà needs in production.

### Added — Public API

- `BonsplitController.onFocusChanged: (() -> Void)?` — fires when the focused pane changes.
- `BonsplitController.onForeignTabDrop` — closure for tab drops whose source pane lives in a different controller (typically another window). Bonsplit reports the drop, the host resolves the source side.
- `BonsplitController.onUnacceptedDragEnd` — closure for drag sessions ending without any drop receiver consuming them. Bonsplit reads the signal from `NSDraggingSession.endedAt(_:operation:)` with `operation == .none`. Enables tear-off into a new window without polling.
- `BonsplitController.onTabContextMenu: ((Tab, PaneID) -> AnyView)?` — host-supplied SwiftUI context-menu builder per tab.
- `BonsplitController.insertExistingTab(...)` — preserve a `TabID` across controllers so host-side state keyed on it can follow the move.
- `PaneID.id` and `TabID.id` are now `public`.

### Added — Internals

- New `TabDragSource` (AppKit-backed `NSDraggingSource`) replaces SwiftUI's `.onDrag` for tabs. AppKit's `draggingSession(_:endedAt:operation:)` is the only source of a definitive drag-end signal.
- `TabDropLifecycle` and `PaneDropLifecycle` enums gate `dropUpdated` callbacks so a stale notification can't re-arm the drop indicator after `performDrop`/`dropExited`.

### Changed

- `BonsplitDelegate` is now `@MainActor`-isolated for Swift 6 strict concurrency.
- `SplitAnimator` uses `nonisolated(unsafe)` on `CVDisplayLink` so the nonisolated `deinit` can stop the link without crossing actor isolation.
- Splitting a pane creates an empty pane by default — was a hardcoded "Welcome" tab upstream.
- Tab transfer UTType identifier renamed from `com.splittabbar.tabtransfer` to `com.smartbyte.bonsplit.tabtransfer`. **Breaking** for hosts that already declared the old identifier in their `Info.plist`.

### Fixed

- Drop overlay is mounted only while a tab drag is in flight. Previously SwiftUI's `.onDrop` registered the underlying `NSView` as `NSDraggingDestination` unconditionally and silently swallowed every file/image drop targeting AppKit views below.
- Exact 50/50 split arithmetic now accounts for divider thickness so the divider lands on the actual midpoint after rounding.
- `programmaticSyncDepth` guard prevents `NSSplitView` resize callbacks from racing each other when one `setPosition` fires while another is still on the stack — without it, sibling panes occasionally snapped to their minimum width during drag.
- 0.5pt hysteresis on container-width tracking eliminates body re-render every frame on sub-pixel window resize.
- `moveTab` short-circuits when source and destination indices are the same (no-op drops).
- Disabled implicit animations on drag-driven transactions for snappier UX.

---

## Upstream history (for reference)

Releases below `0.1.0` are upstream `almonk/bonsplit` versions, captured
here for traceability. They are not Smart-Byte tags — see
[`almonk/bonsplit`](https://github.com/almonk/bonsplit) for the original
release artifacts.

## [1.1.1] - 2025-01-29

### Fixed
- Fixed delegate notifications not being sent when closing tabs ([#2](https://github.com/almonk/bonsplit/issues/2))
  - Tabs now correctly communicate through `BonsplitController` for proper delegate callbacks

### Added
- New public method `closeTab(_ tabId: TabID, inPane paneId: PaneID) -> Bool` for efficient tab closing when pane is known

## [1.1.0] - 2025-01-26

### Added

#### Two-Way Synchronization API
- **Geometry Query**: Query pane layout with pixel coordinates for integration with external programs
  - `layoutSnapshot()` - Get flat list of pane geometries with pixel coordinates
  - `treeSnapshot()` - Get full tree structure for external consumption
  - `findSplit(_:)` - Check if a split exists by UUID

- **Programmatic Updates**: Control divider positions from external sources
  - `setDividerPosition(_:forSplit:fromExternal:)` - Set divider position with loop prevention
  - `setContainerFrame(_:)` - Update container frame when window moves/resizes

- **Geometry Notifications**: Receive callbacks when geometry changes
  - `didChangeGeometry` delegate callback - Notified when any pane geometry changes
  - `shouldNotifyDuringDrag` delegate callback - Opt-in to real-time notifications during divider drag

#### New Types
- `LayoutSnapshot` - Full tree snapshot with pixel coordinates and timestamp
- `PixelRect` - Pixel rectangle for external consumption (Codable, Sendable)
- `PaneGeometry` - Geometry for a single pane including frame and tab info
- `ExternalTreeNode` - Recursive tree representation (enum: pane or split)
- `ExternalPaneNode` - Pane node for external consumption
- `ExternalSplitNode` - Split node with orientation and divider position
- `ExternalTab` - Tab info for external consumption

#### Debug Tools
- Debug window in Example app for testing synchronization features

## [1.0.0] - Initial Release

### Added
- Tab bar with drag-and-drop reordering
- Horizontal and vertical split panes
- 120fps animations
- Configurable appearance and behavior
- Delegate callbacks for all tab and pane events
- Keyboard navigation between panes
- Content view lifecycle options (recreateOnSwitch, keepAllAlive)
- Configuration presets (default, singlePane, readOnly)

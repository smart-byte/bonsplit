import SwiftUI
import UniformTypeIdentifiers

/// Drop zone positions for creating splits
enum DropZone: Equatable {
    case center
    case left
    case right
    case top
    case bottom

    var orientation: SplitOrientation? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    var insertsFirst: Bool {
        switch self {
        case .left, .top: true
        default: false
        }
    }
}

/// Drop lifecycle state to prevent stale `dropUpdated` callbacks from
/// re-arming the indicator after `performDrop`/`dropExited`.
enum PaneDropLifecycle {
    case idle
    case hovering
}

/// Container for a single pane with its tab bar and content area
struct PaneContainerView<Content: View, EmptyContent: View>: View {
    @Environment(BonsplitController.self) private var bonsplitController

    @Bindable var pane: PaneState
    let controller: SplitViewController
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch

    @State private var activeDropZone: DropZone?
    @State private var dropLifecycle: PaneDropLifecycle = .idle

    private var isFocused: Bool {
        controller.focusedPaneId == pane.id
    }

    private var isDragging: Bool {
        controller.draggingTab != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            TabBarView(
                pane: pane,
                isFocused: isFocused,
                showSplitButtons: showSplitButtons
            )

            // Content area with drop zones
            contentAreaWithDropZones
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: isDragging) { _, newValue in
            // Safety net: clear active drop zone when dragging stops
            if !newValue {
                activeDropZone = nil
                dropLifecycle = .idle
            }
        }
    }

    // MARK: - Content Area with Drop Zones

    private var contentAreaWithDropZones: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                // Main content
                contentArea

                // Drop-zone overlay: ONLY mounted while a tab drag is in
                // progress. SwiftUI's `.onDrop` registers the underlying
                // NSView as `NSDraggingDestination` even when
                // `allowsHitTesting(false)` is set and even when the
                // declared UTTypes don't match the dragged item — which
                // silently swallows file/image drops to AppKit views
                // below (NSCollectionView, NSTableView, PinboardCanvas).
                // Mounting conditionally is the only reliable way to
                // keep file-drag affordances working in the host app.
                if isDragging {
                    dropZonesLayer(size: size)
                }

                // Visual placeholder (non-interactive)
                dropPlaceholder(for: activeDropZone, in: size)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
        }
        .clipped()
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if pane.tabs.isEmpty {
            emptyPaneView
        } else {
            switch contentViewLifecycle {
            case .recreateOnSwitch:
                // Original behavior: only render selected tab
                if let selectedTab = pane.selectedTab {
                    contentBuilder(selectedTab, pane.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(!isDragging)
                }

            case .keepAllAlive:
                // macOS-like behavior: keep all tab views in hierarchy.
                //
                // `.opacity(0)` + `.allowsHitTesting(false)` only stop
                // SwiftUI gestures from reaching inactive tabs — AppKit's
                // NSDragging routes to the topmost NSView registered for
                // the dragged types regardless of those modifiers, so a
                // file drop targeted at the visible tab can silently land
                // on a layered inactive NSCollectionView / NSView. The
                // `inactiveTabHidden` modifier wraps the content in a
                // hidden() so the underlying NSHostingView reports
                // `isHidden = true` to AppKit and drops route to the
                // visible tab as expected.
                ZStack {
                    ForEach(pane.tabs) { tab in
                        let isActive = tab.id == pane.selectedTabId
                        contentBuilder(tab, pane.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(!isDragging && isActive)
                            .modifier(InactiveTabHidden(isHidden: !isActive))
                    }
                }
            }
        }
    }

    // MARK: - Drop Zones Layer

    private func dropZonesLayer(size: CGSize) -> some View {
        // Drop zone overlay — only intercepts events while a tab drag is in progress,
        // so AppKit views (NSCollectionView, NSTableView) receive cursor/mouse events normally.
        Color.clear
            .allowsHitTesting(isDragging)
            .onDrop(of: [.tabTransfer], delegate: UnifiedPaneDropDelegate(
                size: size,
                pane: pane,
                controller: controller,
                bonsplitController: bonsplitController,
                activeDropZone: $activeDropZone,
                dropLifecycle: $dropLifecycle
            ))
    }

    // MARK: - Drop Placeholder

    @ViewBuilder
    private func dropPlaceholder(for zone: DropZone?, in size: CGSize) -> some View {
        let placeholderColor = Color.accentColor.opacity(0.25)
        let borderColor = Color.accentColor
        let padding: CGFloat = 4

        // Calculate frame based on zone
        let frame = switch zone {
        case .center, .none:
            CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
        case .left:
            CGRect(x: padding, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
        case .right:
            CGRect(x: size.width / 2, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
        case .top:
            CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height / 2 - padding)
        case .bottom:
            CGRect(x: padding, y: size.height / 2, width: size.width - padding * 2, height: size.height / 2 - padding)
        }

        RoundedRectangle(cornerRadius: 8)
            .fill(placeholderColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 2)
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .opacity((zone != nil && isDragging) ? 1 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: zone)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: isDragging)
    }

    // MARK: - Empty Pane View

    private var emptyPaneView: some View {
        emptyPaneBuilder(pane.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Conditionally wraps the content in `.hidden()`. SwiftUI's
/// `.hidden()` propagates to the underlying `NSHostingView`'s
/// `isHidden = true`, which is the only signal that takes inactive
/// tabs out of AppKit's NSDragging routing. `.opacity(0)` alone leaves
/// the NSView visible to drag-and-drop and silently misroutes drops.
private struct InactiveTabHidden: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        if isHidden {
            content.hidden()
        } else {
            content
        }
    }
}

// MARK: - Unified Pane Drop Delegate

struct UnifiedPaneDropDelegate: DropDelegate {
    let size: CGSize
    let pane: PaneState
    let controller: SplitViewController
    let bonsplitController: BonsplitController
    @Binding var activeDropZone: DropZone?
    @Binding var dropLifecycle: PaneDropLifecycle

    /// Calculate zone based on position within the view
    private func zoneForLocation(_ location: CGPoint) -> DropZone {
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, size.width * edgeRatio)
        let verticalEdge = max(80, size.height * edgeRatio)

        // Check edges first (left/right take priority at corners)
        if location.x < horizontalEdge {
            return .left
        } else if location.x > size.width - horizontalEdge {
            return .right
        } else if location.y < verticalEdge {
            return .top
        } else if location.y > size.height - verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                performDrop(info: info)
            }
        }

        let zone = zoneForLocation(info.location)

        // Same-window fast path: drag and drop share this controller's
        // in-memory `draggingTab`, no pasteboard round-trip needed.
        if let draggedTab = controller.draggingTab,
           let sourcePaneId = controller.dragSourcePaneId
        {
            dropLifecycle = .idle
            activeDropZone = nil
            controller.draggingTab = nil
            controller.dragSourcePaneId = nil

            if zone == .center {
                if sourcePaneId != pane.id {
                    withTransaction(Transaction(animation: nil)) {
                        controller.moveTab(draggedTab, from: sourcePaneId, to: pane.id, atIndex: nil)
                    }
                }
            } else if let orientation = zone.orientation {
                // Remove the tab from its source pane first; splitPaneWithTab
                // re-inserts it into the freshly created pane.
                if let sourcePane = controller.rootNode.findPane(sourcePaneId) {
                    sourcePane.removeTab(draggedTab.id)
                    if sourcePane.tabs.isEmpty, controller.rootNode.allPaneIds.count > 1 {
                        controller.closePane(sourcePaneId)
                    }
                }
                controller.splitPaneWithTab(
                    pane.id,
                    orientation: orientation,
                    tab: draggedTab,
                    insertFirst: zone.insertsFirst
                )
            }
            return true
        }

        // Foreign drop: drag started in another controller (= other
        // window). Read the payload from the pasteboard and let the
        // host app sort out the cross-controller move.
        return acceptForeignDrop(info: info, zone: zone)
    }

    private func acceptForeignDrop(info: DropInfo, zone: DropZone) -> Bool {
        guard let provider = info.itemProviders(for: [.tabTransfer]).first else {
            return false
        }
        let destinationPaneId = pane.id
        let controllerRef = controller
        provider.loadDataRepresentation(forTypeIdentifier: UTType.tabTransfer.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data)
            else { return }
            // For now, foreign drops always land in the destination pane
            // itself (zone == .center or any). Edge-zone splits via foreign
            // drop are intentionally deferred — they need host coordination
            // to know whether the source window survives.
            _ = zone
            Task { @MainActor in
                controllerRef.onForeignTabDrop?(transfer.tab, transfer.sourcePaneId, destinationPaneId, nil)
            }
        }
        Task { @MainActor in
            dropLifecycle = .idle
            activeDropZone = nil
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        dropLifecycle = .hovering
        activeDropZone = zoneForLocation(info.location)
    }

    func dropExited(info _: DropInfo) {
        dropLifecycle = .idle
        activeDropZone = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dropLifecycle == .hovering else {
            return DropProposal(operation: .move)
        }

        activeDropZone = zoneForLocation(info.location)
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Accept any drop whose pasteboard carries our exported UTI —
        // both same-window (controller.draggingTab set) and foreign
        // drops (from another window in this process) qualify.
        info.hasItemsConforming(to: [.tabTransfer])
    }
}

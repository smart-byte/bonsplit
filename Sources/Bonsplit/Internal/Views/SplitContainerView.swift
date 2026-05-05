import AppKit
import SwiftUI

/// Tracks programmatic setPosition calls across all SplitContainerView
/// coordinators. NSSplitView resize callbacks fire synchronously inside
/// setPosition; if a callback triggers another coordinator's syncPosition
/// while the first is still in flight, the second call observes a model
/// position that doesn't match the in-progress geometry and snaps a pane
/// to its minimum width. Reading this depth lets a sibling coordinator
/// step out of the way while any setPosition is on the stack.
@MainActor
private var splitContainerProgrammaticSyncDepth = 0

/// SwiftUI wrapper around NSSplitView for native split behavior
struct SplitContainerView<Content: View, EmptyContent: View>: NSViewRepresentable {
    @Bindable var splitState: SplitState
    let controller: SplitViewController
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    /// Callback when geometry changes. Bool indicates if change is during active divider drag.
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(splitState: splitState, onGeometryChange: onGeometryChange)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = splitState.orientation == .horizontal
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        // First child
        let firstHosting = makeHostingView(for: splitState.first, coordinator: context.coordinator)
        splitView.addArrangedSubview(firstHosting)

        // Second child
        let secondHosting = makeHostingView(for: splitState.second, coordinator: context.coordinator)
        splitView.addArrangedSubview(secondHosting)

        context.coordinator.splitView = splitView

        // Capture animation origin before it gets cleared
        let animationOrigin = splitState.animationOrigin

        // Determine which pane is new (will be hidden initially)
        let newPaneIndex = animationOrigin == .fromFirst ? 0 : 1

        if animationOrigin != nil {
            // Clear immediately so we don't re-animate on updates
            splitState.animationOrigin = nil

            // Hide the NEW pane immediately to prevent flash
            splitView.arrangedSubviews[newPaneIndex].isHidden = true

            // Track that we're animating (skip delegate position updates)
            context.coordinator.isAnimating = true
        }

        // Wait for view to be added to window
        DispatchQueue.main.async {
            let totalSize = splitState.orientation == .horizontal
                ? splitView.bounds.width
                : splitView.bounds.height
            // The divider itself takes up some pixels — position math has to
            // account for it, otherwise the right pane is consistently a
            // dividerThickness narrower than the left and "exact 50/50"
            // splits actually land off-centre.
            let availableSize = max(totalSize - splitView.dividerThickness, 0)

            guard availableSize > 0 else { return }

            if animationOrigin != nil {
                // Position at edge while new pane is hidden
                let startPosition: CGFloat = animationOrigin == .fromFirst ? 0 : availableSize
                context.coordinator.setPositionSafely(startPosition, in: splitView, layout: true)

                let targetPosition = availableSize * 0.5
                splitState.dividerPosition = 0.5

                // Wait for layout
                DispatchQueue.main.async {
                    // Show the new pane and animate
                    splitView.arrangedSubviews[newPaneIndex].isHidden = false

                    SplitAnimator.shared.animate(
                        splitView: splitView,
                        from: startPosition,
                        to: targetPosition
                    ) {
                        context.coordinator.isAnimating = false
                        // Re-assert exact 0.5 after animation; otherwise
                        // accumulated pixel rounding can leave the divider
                        // visibly off-centre.
                        splitState.dividerPosition = 0.5
                        context.coordinator.lastAppliedPosition = 0.5
                    }
                }
            } else {
                // No animation - just set the position
                let position = availableSize * splitState.dividerPosition
                context.coordinator.setPositionSafely(position, in: splitView, layout: false)
            }
        }

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        // Update orientation if changed
        splitView.isVertical = splitState.orientation == .horizontal

        // Update children
        let subviews = splitView.arrangedSubviews
        if subviews.count >= 2 {
            updateHostingView(subviews[0], for: splitState.first, coordinator: context.coordinator)
            updateHostingView(subviews[1], for: splitState.second, coordinator: context.coordinator)
        }

        // Access dividerPosition to ensure SwiftUI tracks this dependency
        // Then sync if the position changed externally
        let currentPosition = splitState.dividerPosition
        context.coordinator.syncPosition(currentPosition, in: splitView)
    }

    // MARK: - Helpers

    private func makeHostingView(for node: SplitNode, coordinator: Coordinator) -> NSView {
        let hostingController = NSHostingController(rootView: AnyView(makeView(for: node)))
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator.hostedNodeIDs[ObjectIdentifier(hostingController.view)] = node.id
        return hostingController.view
    }

    private func updateHostingView(_ view: NSView, for node: SplitNode, coordinator: Coordinator) {
        // SwiftUI re-runs `updateNSView` on every parent invalidation —
        // including ~60fps during a window resize. Re-assigning `rootView`
        // each time forces SwiftUI to fully reconcile the AnyView-wrapped
        // subtree (AnyView blocks structural diffing). Skip the swap when
        // the underlying split node is the same; pure SwiftUI state changes
        // inside the subtree propagate through the existing hosting view.
        let viewID = ObjectIdentifier(view)
        if coordinator.hostedNodeIDs[viewID] == node.id { return }
        if let hostingView = view as? NSHostingView<AnyView> {
            hostingView.rootView = AnyView(makeView(for: node))
            coordinator.hostedNodeIDs[viewID] = node.id
        }
    }

    @ViewBuilder
    private func makeView(for node: SplitNode) -> some View {
        switch node {
        case let .pane(paneState):
            PaneContainerView(
                pane: paneState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle
            )
        case let .split(nestedSplitState):
            SplitContainerView(
                splitState: nestedSplitState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange
            )
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSSplitViewDelegate {
        let splitState: SplitState
        weak var splitView: NSSplitView?
        var isAnimating = false
        var onGeometryChange: ((_ isDragging: Bool) -> Void)?
        /// Track last applied position to detect external changes
        var lastAppliedPosition: CGFloat = 0.5
        /// Guard programmatic setPosition re-entrancy from resize callbacks.
        var isSyncingProgrammatically = false
        /// Track if user is actively dragging the divider
        var isDragging = false
        /// UUID of the split node currently mounted in each child hosting
        /// view, keyed by the view's identity. Lets `updateHostingView`
        /// skip the AnyView-wrapping rootView swap when the underlying
        /// node hasn't actually changed (cheap diff during window resize).
        var hostedNodeIDs: [ObjectIdentifier: UUID] = [:]

        init(splitState: SplitState, onGeometryChange: ((_ isDragging: Bool) -> Void)?) {
            self.splitState = splitState
            self.onGeometryChange = onGeometryChange
            lastAppliedPosition = splitState.dividerPosition
        }

        /// Single chokepoint for every programmatic setPosition. NSSplitView
        /// fires `splitViewDidResizeSubviews` synchronously inside
        /// `setPosition`; without this guard a resize callback can re-enter
        /// `syncPosition` and apply a stale model position over the
        /// in-progress geometry, snapping a pane to its minimum width.
        func setPositionSafely(_ position: CGFloat, in splitView: NSSplitView, layout: Bool = true) {
            isSyncingProgrammatically = true
            splitContainerProgrammaticSyncDepth += 1
            defer {
                isSyncingProgrammatically = false
                splitContainerProgrammaticSyncDepth = max(0, splitContainerProgrammaticSyncDepth - 1)
            }
            splitView.setPosition(position, ofDividerAt: 0)
            // Skip the redundant layout pass while a user-driven drag is in
            // progress (window edge or divider): NSSplitView already laid
            // out its subviews, our extra `layoutSubtreeIfNeeded()` doubles
            // the work per frame and is the dominant cost in resize lag.
            if layout, !isDragging {
                splitView.layoutSubtreeIfNeeded()
            }
        }

        /// Apply external position changes to the NSSplitView
        func syncPosition(_ statePosition: CGFloat, in splitView: NSSplitView) {
            guard !isAnimating else { return }
            // Don't re-enter while any coordinator (this one or a sibling
            // higher up the split tree) is in the middle of a programmatic
            // setPosition.
            guard !isSyncingProgrammatically else { return }
            guard splitContainerProgrammaticSyncDepth == 0 else { return }

            // Check if position changed externally (not from user drag)
            if abs(statePosition - lastAppliedPosition) > 0.01 {
                let totalSize = splitState.orientation == .horizontal
                    ? splitView.bounds.width
                    : splitView.bounds.height
                let availableSize = max(totalSize - splitView.dividerThickness, 0)

                guard availableSize > 0 else { return }

                let pixelPosition = availableSize * statePosition
                setPositionSafely(pixelPosition, in: splitView, layout: true)
                lastAppliedPosition = statePosition
            }
        }

        func splitViewWillResizeSubviews(_: Notification) {
            // Detect if this is a user drag by checking mouse state
            if let event = NSApp.currentEvent, event.type == .leftMouseDragged {
                isDragging = true
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // Skip position updates during animation
            guard !isAnimating else { return }
            guard let splitView = notification.object as? NSSplitView else { return }
            // Skip only OUR own programmatic setPosition echo — the global
            // depth must NOT gate this path. A nested split's programmatic
            // sync (triggered by a parent drag changing geometry) would
            // otherwise swallow the parent's own user-drag events and the
            // parent would re-apply a stale dividerPosition, snapping a
            // pane to zero width.
            guard !isSyncingProgrammatically else { return }

            let totalSize = splitState.orientation == .horizontal
                ? splitView.bounds.width
                : splitView.bounds.height
            let availableSize = max(totalSize - splitView.dividerThickness, 0)

            guard availableSize > 0 else { return }

            if let firstSubview = splitView.arrangedSubviews.first {
                let dividerPosition = splitState.orientation == .horizontal
                    ? firstSubview.frame.width
                    : firstSubview.frame.height

                var normalizedPosition = dividerPosition / availableSize

                // Snap to exact 0.5 for tiny pixel-rounding drift, so
                // non-drag resizes don't slowly walk the divider away
                // from centre over many resize events.
                if abs(normalizedPosition - 0.5) < 0.01 {
                    normalizedPosition = 0.5
                }

                // Check if drag ended (mouse up)
                let wasDragging = isDragging
                if let event = NSApp.currentEvent, event.type == .leftMouseUp {
                    isDragging = false
                }

                // Hysteresis on the SwiftUI write: NSSplitView re-fires this
                // callback every frame during a window-edge resize as pixel
                // rounding nudges `firstSubview.frame.width` by sub-pixel
                // amounts. Writing `splitState.dividerPosition` invalidates
                // every view that observes the @Bindable splitState — and
                // with nested splits the cascade multiplies. 0.5% sits well
                // below the perceptual threshold even on wide windows
                // (e.g. 5 px on a 1000 px split) but eliminates the
                // pixel-jitter-driven write storm.
                let drift = abs(normalizedPosition - lastAppliedPosition)
                if drift > 0.005 {
                    splitState.dividerPosition = normalizedPosition
                    lastAppliedPosition = normalizedPosition
                }
                // Notify geometry change with drag state — even when we
                // skip the SwiftUI write, downstream listeners (e.g. the
                // host's saveCurrentLayout coalescer) may want the event.
                onGeometryChange?(wasDragging)
            }
        }

        func splitView(_: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt _: Int) -> CGFloat {
            // Allow edge positions during animation
            guard !isAnimating else { return proposedMinimumPosition }
            return max(proposedMinimumPosition, TabBarMetrics.minimumPaneWidth)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt _: Int) -> CGFloat {
            // Allow edge positions during animation
            guard !isAnimating else { return proposedMaximumPosition }
            let totalSize = splitState.orientation == .horizontal
                ? splitView.bounds.width
                : splitView.bounds.height
            return min(proposedMaximumPosition, totalSize - splitView.dividerThickness - TabBarMetrics.minimumPaneWidth)
        }
    }
}

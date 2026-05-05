import SwiftUI

/// Main container view that renders the entire split tree (internal implementation)
struct SplitViewContainer<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            splitNodeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .onChange(of: geometry.size) { _, _ in
                    updateContainerFrame(geometry: geometry)
                }
                .onAppear {
                    updateContainerFrame(geometry: geometry)
                }
        }
    }

    private func updateContainerFrame(geometry: GeometryProxy) {
        // Get frame in global coordinate space
        let frame = geometry.frame(in: .global)
        // `controller.containerFrame` is read by every observer of the
        // @Observable SplitViewController (every SplitNodeView, every
        // PaneContainerView, …). Writing it on every sub-pixel jitter
        // during a window-edge or sidebar drag triggers a full
        // observer-graph invalidation 60fps. Snap the write to ≥1pt
        // deltas — pixel rounding below that is invisible and only
        // feeds the cascade.
        let last = controller.containerFrame
        if abs(frame.size.width - last.size.width) > 1 ||
            abs(frame.size.height - last.size.height) > 1 ||
            abs(frame.origin.x - last.origin.x) > 1 ||
            abs(frame.origin.y - last.origin.y) > 1
        {
            controller.containerFrame = frame
        }
        onGeometryChange?(false) // Container resize is not a drag
    }

    private var splitNodeContent: some View {
        SplitNodeView(
            node: controller.rootNode,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange
        )
    }
}

import AppKit
import SwiftUI

/// Recursively renders a split node (pane or split)
struct SplitNodeView<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let node: SplitNode
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?

    var body: some View {
        switch node {
        case let .pane(paneState):
            // Wrap in NSHostingController for proper layout constraints
            SinglePaneWrapper(
                pane: paneState,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle
            )

        case let .split(splitState):
            SplitContainerView(
                splitState: splitState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange
            )
        }
    }
}

/// Wrapper that uses NSHostingController for proper AppKit layout constraints
struct SinglePaneWrapper<Content: View, EmptyContent: View>: NSViewRepresentable {
    @Environment(SplitViewController.self) private var controller

    let pane: PaneState
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch

    func makeNSView(context: Context) -> NSView {
        let paneView = PaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle
        )
        let hostingController = NSHostingController(rootView: paneView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // Store hosting controller to keep it alive, plus the mounted
        // pane id so `updateNSView` can skip redundant rootView swaps.
        context.coordinator.hostingController = hostingController
        context.coordinator.lastPaneID = pane.id

        return containerView
    }

    func updateNSView(_: NSView, context: Context) {
        // SwiftUI re-runs `updateNSView` on every parent invalidation —
        // including ~60fps during a window resize. Building a fresh
        // `PaneContainerView` struct and re-assigning `rootView` each
        // frame forces SwiftUI to diff the entire pane subtree
        // (TabBarView + content). Skip the swap while the same pane
        // is mounted — its `@Observable` PaneState propagates state
        // changes through the existing hosting controller.
        guard context.coordinator.lastPaneID != pane.id else { return }
        let paneView = PaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle
        )
        context.coordinator.hostingController?.rootView = paneView
        context.coordinator.lastPaneID = pane.id
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var hostingController: NSHostingController<PaneContainerView<Content, EmptyContent>>?
        var lastPaneID: PaneID?
    }
}

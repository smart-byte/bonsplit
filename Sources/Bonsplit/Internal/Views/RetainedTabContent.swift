import AppKit
import SwiftUI

/// Keeps tab identity alive while isolating inactive content from pane resizing.
/// Hiding a SwiftUI child alone still passes new layout proposals through it.
struct RetainedTabContent<Content: View>: NSViewRepresentable {
    let isActive: Bool
    let content: Content

    func makeNSView(context: Context) -> RetainedTabContainer {
        let view = RetainedTabContainer()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RetainedTabContainer, context: Context) {
        // A separate hosting boundary must receive the caller's environment,
        // including the controllers and the app's environment objects.
        view.update(
            content: AnyView(content.environment(\.self, context.environment)),
            isActive: isActive
        )
    }
}

/// The outer view follows the pane; only the selected tab's hosting view follows
/// the outer bounds. No constraints or autoresizing link the two while inactive.
@MainActor
final class RetainedTabContainer: NSView {
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var pendingContent: AnyView?
    private(set) var isActive = false
    private var hasInitialSize = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = []
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    func update(content: AnyView, isActive: Bool) {
        if self.isActive, !isActive,
           let responder = window?.firstResponder as? NSView,
           responder === hostingView || responder.isDescendant(of: hostingView)
        {
            // Retaining an editor/terminal must not leave keyboard input routed
            // into a hidden tab. Do not disturb focus belonging to another pane.
            window?.makeFirstResponder(nil)
        }
        self.isActive = isActive
        pendingContent = content
        // Native hiding also excludes inactive AppKit file-drop destinations.
        // Unlike conditional SwiftUI .hidden(), it doesn't replace the subtree.
        hostingView.isHidden = !isActive
        if isActive {
            applyPendingContent()
            resizeContentIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        // Give never-selected tabs one initial size/content installation, but
        // do not forward subsequent parent resizes or root updates to them.
        if isActive || !hasInitialSize {
            applyPendingContent()
            resizeContentIfNeeded()
        }
    }

    private func applyPendingContent() {
        guard let pendingContent else { return }
        hostingView.rootView = pendingContent
        self.pendingContent = nil
    }

    private func resizeContentIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        hasInitialSize = true
        if hostingView.frame != bounds {
            hostingView.frame = bounds
        }
    }
}

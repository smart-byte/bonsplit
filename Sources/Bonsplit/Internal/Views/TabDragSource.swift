import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit-backed drag source for tab items. Replaces SwiftUI's `.onDrag`
/// for tabs because we need a definitive callback when the drag ends —
/// `.onDrag` only hands us back an NSItemProvider when the drag begins
/// and tells us nothing when it ends. `NSDraggingSource` provides
/// `draggingSession(_:endedAt:operation:)`, which fires for every drag
/// end and reports the final operation: `.none` means no drop receiver
/// accepted the drop (the user dropped into empty space, which is the
/// signal the host app uses to spawn a new window for tear-off).
///
/// Visually identical to the old `.onDrag` cell — the SwiftUI tab body
/// is hosted unchanged via `NSHostingView`, so layout, hover and click
/// behaviour stay the same.
struct TabDragSource<Content: View>: NSViewRepresentable {
    let tab: TabItem
    let sourcePaneId: PaneID
    let controller: SplitViewController
    let preview: () -> AnyView
    @ViewBuilder let content: () -> Content

    func makeNSView(context _: Context) -> TabDragSourceNSView {
        let view = TabDragSourceNSView()
        view.update(
            tab: tab,
            sourcePaneId: sourcePaneId,
            controller: controller,
            previewBuilder: preview
        )
        view.embed(content: content())
        view.installPanRecognizer()
        return view
    }

    func updateNSView(_ nsView: TabDragSourceNSView, context _: Context) {
        nsView.update(
            tab: tab,
            sourcePaneId: sourcePaneId,
            controller: controller,
            previewBuilder: preview
        )
        nsView.refresh(content: content())
    }
}

/// AppKit drag-source view. Hosts a SwiftUI tab body and starts an
/// `NSDraggingSession` once the user pans past the system threshold.
/// Forwards drag-lifecycle events back to the controller so Bonsplit
/// (and its host) can react to "drag ended without a drop".
final class TabDragSourceNSView: NSView, NSDraggingSource {
    private var tab: TabItem?
    private var sourcePaneId: PaneID?
    private weak var controller: SplitViewController?
    private var previewBuilder: (() -> AnyView)?
    private var host: NSHostingView<AnyView>?

    func update(
        tab: TabItem,
        sourcePaneId: PaneID,
        controller: SplitViewController,
        previewBuilder: @escaping () -> AnyView
    ) {
        self.tab = tab
        self.sourcePaneId = sourcePaneId
        self.controller = controller
        self.previewBuilder = previewBuilder
    }

    func embed(content: some View) {
        let host = NSHostingView(rootView: AnyView(content))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.host = host
    }

    func refresh(content: some View) {
        host?.rootView = AnyView(content)
    }

    func installPanRecognizer() {
        // NSPanGestureRecognizer fires once the user has dragged past the
        // system's drag threshold (~3pt). Plain mouseDown/mouseUp still
        // pass through to the SwiftUI host so tab clicks (select/close)
        // keep working unchanged.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began,
              let event = NSApp.currentEvent
        else { return }
        beginDrag(with: event)
    }

    private func beginDrag(with event: NSEvent) {
        guard let controller, let tab, let sourcePaneId else { return }

        // Mark the drag as in-flight so same-window drop receivers can
        // take their fast path through `controller.draggingTab` without
        // touching the pasteboard.
        controller.draggingTab = tab
        controller.dragSourcePaneId = sourcePaneId

        let transfer = TabTransferData(tab: tab, sourcePaneId: sourcePaneId.id)
        guard let data = try? JSONEncoder().encode(transfer) else {
            controller.draggingTab = nil
            controller.dragSourcePaneId = nil
            return
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.tabTransfer.identifier))

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = renderDragImage()
        draggingItem.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        // Suppress AppKit's default snap-back animation. Tab tear-off
        // looks much cleaner when the drag image just disappears at
        // mouseUp instead of flying back to the source tab right
        // before the new window appears at the same spot.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    private func renderDragImage() -> NSImage {
        if let previewBuilder {
            // ImageRenderer renders in an isolated context that ignores
            // the host window's effectiveAppearance. Forward the
            // window's light/dark mode explicitly so dynamic NSColors
            // resolve to the same values the user sees on screen.
            let isDark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let themedPreview = previewBuilder()
                .environment(\.colorScheme, isDark ? .dark : .light)
            let renderer = ImageRenderer(content: themedPreview)
            renderer.scale = window?.backingScaleFactor ?? 2
            if let nsImage = renderer.nsImage {
                return nsImage
            }
        }
        // Fallback: snapshot the hosted view itself. Worst case still
        // gives a recognisable drag image rather than a blank rectangle.
        let size = bounds.size
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }
        return NSImage(size: size)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor _: NSDraggingContext
    ) -> NSDragOperation {
        [.move, .copy]
    }

    func draggingSession(
        _: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let controller, let tab, let sourcePaneId else { return }

        // rawValue == 0 means no drop receiver accepted the drop —
        // canonical "tear off" signal. Comparing via `isEmpty` avoids
        // the `operation == .none` trap where Swift can resolve `.none`
        // to `Optional.none` instead of `NSDragOperation.none`,
        // silently turning the comparison into `operation == nil`
        // which is always false on a non-optional.
        if operation.isEmpty {
            controller.onUnacceptedDragEnd?(tab, sourcePaneId, screenPoint)
        }
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
    }
}

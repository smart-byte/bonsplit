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
    /// Fired on the very first `mouseDown` over the tab — runs the
    /// host's selection action immediately, matching the macOS-native
    /// "tabs activate on press, not on release" behaviour (Safari,
    /// Xcode, Finder sidebar, …). The previous SwiftUI `.onTapGesture`
    /// only fired on `mouseUp` and produced a perceptible delay
    /// between press and selection.
    let onClick: () -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context _: Context) -> TabDragSourceNSView {
        let view = TabDragSourceNSView()
        view.update(
            tab: tab,
            sourcePaneId: sourcePaneId,
            controller: controller,
            previewBuilder: preview,
            onClick: onClick
        )
        view.embed(content: content())
        view.installDragRecognizer()
        return view
    }

    func updateNSView(_ nsView: TabDragSourceNSView, context _: Context) {
        nsView.update(
            tab: tab,
            sourcePaneId: sourcePaneId,
            controller: controller,
            previewBuilder: preview,
            onClick: onClick
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
    private var onClick: (() -> Void)?
    private var host: NSHostingView<AnyView>?

    func update(
        tab: TabItem,
        sourcePaneId: PaneID,
        controller: SplitViewController,
        previewBuilder: @escaping () -> AnyView,
        onClick: @escaping () -> Void
    ) {
        self.tab = tab
        self.sourcePaneId = sourcePaneId
        self.controller = controller
        self.previewBuilder = previewBuilder
        self.onClick = onClick
    }

    // MARK: - Press-to-select

    override func mouseDown(with event: NSEvent) {
        // macOS-native tab selection fires on press (Safari / Xcode /
        // Finder sidebar all do this), not on release. SwiftUI's
        // `.onTapGesture` would only fire after `mouseUp` and produced
        // a perceptible delay. Calling super first lets the responder
        // chain (and our drag-threshold recognizer) handle the event
        // afterwards as usual.
        super.mouseDown(with: event)
        onClick?()
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

    func installDragRecognizer() {
        // Custom NSGestureRecognizer that simulates a pan with an
        // explicit 6pt threshold. NSPanGestureRecognizer on macOS has
        // no configurable minimumDistance and fires on the first
        // mouseDragged — even a 1pt mouse jitter during a click would
        // start a drag and rob SwiftUI's `.onTapGesture` of its
        // selection event. Holding the recognizer in `.possible` until
        // the threshold is crossed lets normal mouseDown/mouseUp
        // events fall through to the SwiftUI host unchanged, so tab
        // selection and close-button clicks keep working. 6pt is wide
        // enough to absorb realistic trackpad / mouse jitter during a
        // click (often 4-5pt) while still feeling instantaneous on a
        // deliberate drag, which moves 20+ pt in the first frame.
        let recognizer = TabDragGestureRecognizer()
        recognizer.threshold = 6
        recognizer.onDragStart = { [weak self] event in
            self?.beginDrag(with: event)
        }
        addGestureRecognizer(recognizer)
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

// MARK: - Custom drag-threshold gesture recognizer

/// `NSGestureRecognizer` subclass that behaves like
/// `NSPanGestureRecognizer` but only transitions to `.began` once the
/// cursor has moved beyond `threshold` points from the mouse-down
/// location. While the recognizer is in `.possible`, mouse events
/// continue to flow through to the view's normal responder chain —
/// in particular, SwiftUI's `.onTapGesture` keeps firing for short
/// clicks even if the cursor jitters by 1–2 px during the click.
///
/// Default macOS `NSPanGestureRecognizer` has no configurable minimum
/// distance and fires on the first `mouseDragged`, which made it
/// impossible to select a tab without accidentally starting a drag.
final class TabDragGestureRecognizer: NSGestureRecognizer {
    /// Distance in points the cursor must travel from `mouseDown`
    /// before the recognizer fires `.began`. 6pt accommodates the
    /// 4-5pt jitter typical for trackpad clicks while still feeling
    /// instantaneous on deliberate drags.
    var threshold: CGFloat = 6

    /// Fired once when the recognizer transitions to `.began`. Receives
    /// the originating event so the consumer can hand it to
    /// `beginDraggingSession(with:event:source:)`.
    var onDragStart: ((NSEvent) -> Void)?

    private var startPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        state = .possible
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        if dx * dx + dy * dy >= threshold * threshold {
            // Crossed the threshold — promote to .began so AppKit
            // routes subsequent events to us. The drag session itself
            // is started immediately via the callback so the source
            // view's drag-image fly-along feels instantaneous.
            state = .began
            onDragStart?(event)
        }
    }

    override func mouseUp(with _: NSEvent) {
        // Click finished without crossing the threshold — fail the
        // recognizer so AppKit knows we never really started a
        // gesture. SwiftUI's `.onTapGesture` already received its
        // mouseDown/mouseUp pair through the normal responder chain
        // while we sat in `.possible`, so the tab selection has
        // already fired by this point.
        if state == .possible {
            state = .failed
        } else {
            state = .ended
        }
        startPoint = nil
    }

    override func reset() {
        super.reset()
        startPoint = nil
    }
}

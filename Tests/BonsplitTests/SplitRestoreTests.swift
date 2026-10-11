import AppKit
@testable import Bonsplit
import SwiftUI
import XCTest

/// A split created at a known divider position (a restored layout) has to keep it: in the
/// model right away, and on screen once the views are mounted and laid out.
@MainActor
final class SplitRestoreTests: XCTestCase {
    // MARK: - Model

    func testSplitPaneWithDividerPositionStartsSettled() throws {
        let controller = BonsplitController()
        let root = try XCTUnwrap(controller.focusedPaneId)

        XCTAssertNotNil(controller.splitPane(root, orientation: .horizontal, dividerPosition: 0.3))

        guard case let .split(split) = controller.treeSnapshot() else { return XCTFail("expected a split") }
        XCTAssertEqual(split.dividerPosition, 0.3, accuracy: 1e-9)
        XCTAssertNil(controller.internalController.allSplits.first?.animationOrigin)
    }

    func testRestoredDividerPositionIsClampedLikeSetDividerPosition() throws {
        let controller = BonsplitController()
        let root = try XCTUnwrap(controller.focusedPaneId)
        let second = try XCTUnwrap(controller.splitPane(root, orientation: .horizontal, dividerPosition: 0.95))
        XCTAssertNotNil(controller.splitPane(second, orientation: .vertical, dividerPosition: 0.0))

        guard case let .split(outer) = controller.treeSnapshot(),
              case let .split(inner) = outer.second else { return XCTFail("expected nested splits") }
        XCTAssertEqual(outer.dividerPosition, 0.9, accuracy: 1e-9)
        XCTAssertEqual(inner.dividerPosition, 0.1, accuracy: 1e-9)
    }

    func testSplitWithoutDividerPositionKeepsTheEntryAnimation() throws {
        let controller = BonsplitController()
        let root = try XCTUnwrap(controller.focusedPaneId)

        XCTAssertNotNil(controller.splitPane(root, orientation: .horizontal))

        guard case let .split(split) = controller.treeSnapshot() else { return XCTFail("expected a split") }
        XCTAssertEqual(split.dividerPosition, 1.0, accuracy: 1e-9)
        XCTAssertEqual(controller.internalController.allSplits.first?.animationOrigin, .fromSecond)
    }

    // MARK: - Mounted

    /// Mirrors a host's restore: the view comes up with a single empty pane and the saved tree
    /// is replayed afterwards. The divider positions have to survive the first layout, which
    /// used to read NSSplitView's even initial split back into the model (and reset it to 0.5).
    ///
    /// Waits on conditions with bounded deadlines rather than fixed sleeps. Only an
    /// environment that can't lay out a hosted view at all skips the test.
    func testMountedSplitsKeepTheirRestoredDividerPositions() throws {
        let controller = BonsplitController()
        let host = NSHostingView(rootView: BonsplitView(controller: controller) { tab, _ in
            Text(tab.title)
        } emptyPane: { _ in
            EmptyView()
        })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        let rootMounted = spin(host, timeout: 5) { controller.internalController.containerFrame.width > 0 }
        try XCTSkipUnless(rootMounted, "The hosted Bonsplit view never got a layout; no usable window server here.")

        let root = try XCTUnwrap(controller.focusedPaneId)
        let right = try XCTUnwrap(controller.splitPane(root, orientation: .horizontal, dividerPosition: 0.3))
        let bottomLeft = try XCTUnwrap(controller.splitPane(root, orientation: .vertical, dividerPosition: 0.65))
        for (title, pane) in [("A", root), ("B", bottomLeft), ("C", right)] {
            controller.createTab(title: title, icon: nil, inPane: pane)
        }

        let splitsMounted = spin(host, timeout: 5) {
            let splits = self.splitViews(in: host)
            return splits.count == 2 && splits.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 }
        }
        XCTAssertTrue(splitsMounted, "Both split views should mount once the tree is replayed")
        guard splitsMounted else { return }

        // The reset used to land a fraction of a second after the mount, so "right now" proves
        // nothing: the positions have to hold, model and screen alike, for a while.
        func positions() -> (model: [Double], screen: [Double])? {
            guard case let .split(outer) = controller.treeSnapshot(),
                  case let .split(inner) = outer.first else { return nil }
            let splits = splitViews(in: host)
            guard let outerView = splits.first(where: \.isVertical),
                  let innerView = splits.first(where: { !$0.isVertical }),
                  let outerShare = firstChildShare(of: outerView),
                  let innerShare = firstChildShare(of: innerView) else { return nil }
            return ([outer.dividerPosition, inner.dividerPosition], [outerShare, innerShare])
        }
        func holdsRestoredPositions() -> Bool {
            guard let current = positions() else { return false }
            return zip(current.model, [0.3, 0.65]).allSatisfy { abs($0 - $1) < 0.01 }
                && zip(current.screen, [0.3, 0.65]).allSatisfy { abs($0 - $1) < 0.02 }
        }

        var holdingSince: Date?
        let settled = spin(host, timeout: 5) {
            guard holdsRestoredPositions() else {
                holdingSince = nil
                return false
            }
            let since = holdingSince ?? Date()
            holdingSince = since
            return Date().timeIntervalSince(since) >= 0.5
        }
        XCTAssertTrue(settled, "Expected outer 0.3 / inner 0.65, got \(String(describing: positions()))")
    }

    // MARK: - Helpers

    /// Lays `view` out and runs the run loop until `condition` holds or `timeout` passes,
    /// so a broken environment ends the test instead of hanging it.
    private func spin(_ view: NSView, timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        let own = (view as? NSSplitView).map { [$0] } ?? []
        return own + view.subviews.flatMap { splitViews(in: $0) }
    }

    /// The first child's share of the split as it is laid out on screen (divider excluded).
    private func firstChildShare(of split: NSSplitView) -> Double? {
        guard let first = split.arrangedSubviews.first else { return nil }
        let total = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
        guard total > 0 else { return nil }
        return Double((split.isVertical ? first.frame.width : first.frame.height) / total)
    }
}

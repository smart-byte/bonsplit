import AppKit
@testable import Bonsplit
import SwiftUI
import XCTest

@MainActor
final class RetainedTabContentTests: XCTestCase {
    func testInactiveHostingFrameStaysFrozenAndCatchesUpOnSelection() {
        let container = RetainedTabContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.update(content: AnyView(Color.red), isActive: true)
        let host = container.hostingView
        XCTAssertEqual(host.frame.size, CGSize(width: 800, height: 600))
        container.update(content: AnyView(Color.red), isActive: false)
        for step in 0 ..< 100 {
            container.frame.size = CGSize(width: 500 + step, height: 300 + step)
            container.layout()
            XCTAssertEqual(host.frame.size, CGSize(width: 800, height: 600))
            XCTAssertTrue(host.isHidden)
        }
        container.update(content: AnyView(Color.blue), isActive: true)
        XCTAssertTrue(container.hostingView === host)
        XCTAssertEqual(host.frame, container.bounds)
        XCTAssertFalse(host.isHidden)
    }

    func testInitiallyInactiveTabReceivesOnlyOneInitialSize() {
        let container = RetainedTabContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.update(content: AnyView(Color.red), isActive: false)
        container.layout()
        let initial = container.hostingView.frame
        XCTAssertEqual(initial.size, container.bounds.size)
        container.frame.size = CGSize(width: 300, height: 200)
        container.layout()
        XCTAssertEqual(container.hostingView.frame, initial)
    }

    func testHidingTabClearsItsResponderButNotAnotherPanesResponder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = try RetainedTabContainer(frame: XCTUnwrap(window.contentView?.bounds))
        window.contentView?.addSubview(container)
        container.update(content: AnyView(Color.red), isActive: true)
        let editor = ProbeView()
        container.hostingView.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        container.update(content: AnyView(Color.red), isActive: false)
        XCTAssertFalse(window.firstResponder === editor)

        let other = ProbeView()
        window.contentView?.addSubview(other)
        container.update(content: AnyView(Color.red), isActive: true)
        XCTAssertTrue(window.makeFirstResponder(other))
        container.update(content: AnyView(Color.red), isActive: false)
        XCTAssertTrue(window.firstResponder === other)
    }

    func testSwiftUIStateAndEnvironmentSurviveTabSwitchAndResize() throws {
        let model = HarnessModel()
        let recorder = Recorder()
        let root = NSHostingView(rootView: Harness(model: model).environmentObject(recorder))
        root.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        settle(root)
        let first = try XCTUnwrap(recorder.views[0])
        let token = try XCTUnwrap(recorder.tokens[0])
        XCTAssertEqual(recorder.values[0], "initial")

        model.selected = 1
        settle(root)
        let frozenFrame = first.frame
        let initialCalls = first.resizeCalls
        for step in 0 ..< 12 {
            window.setContentSize(CGSize(width: 500 + step * 10, height: 350 + step * 10))
            settle(root)
        }
        XCTAssertEqual(first.frame, frozenFrame)
        XCTAssertEqual(first.resizeCalls, initialCalls)
        XCTAssertTrue(first.isHiddenOrHasHiddenAncestor)

        model.value = "updated"
        settle(root)
        model.selected = 0
        settle(root)
        XCTAssertTrue(recorder.views[0] === first)
        XCTAssertEqual(recorder.tokens[0], token)
        XCTAssertEqual(recorder.values[0], "updated")
        XCTAssertFalse(first.isHiddenOrHasHiddenAncestor)
        XCTAssertNotEqual(first.frame.size, frozenFrame.size)
        XCTAssertEqual(recorder.makeCounts[0], 1)
    }

    func testRealHostingHierarchyStopsMeasuringInactiveTabsComparedWithLegacyStack() throws {
        let legacy = try resizeCounts(frozen: false)
        let frozen = try resizeCounts(frozen: true)
        XCTAssertGreaterThan(legacy[0, default: 0], 0)
        XCTAssertGreaterThan(legacy[1, default: 0], 0)
        XCTAssertGreaterThan(legacy[2, default: 0], 0)
        XCTAssertGreaterThan(frozen[0, default: 0], 0)
        XCTAssertEqual(frozen[1, default: 0], 0)
        XCTAssertEqual(frozen[2, default: 0], 0)
    }

    private func resizeCounts(frozen: Bool) throws -> [Int: Int] {
        let model = HarnessModel()
        let recorder = Recorder()
        let root = NSHostingView(rootView: Harness(model: model, frozen: frozen).environmentObject(recorder))
        root.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        settle(root)
        for index in 0 ..< 3 {
            let view = try XCTUnwrap(recorder.views[index])
            view.resizeCalls = 0
        }
        recorder.measureCounts = [:]
        for step in 0 ..< 12 {
            window.setContentSize(CGSize(width: 500 + step * 10, height: 350 + step * 10))
            settle(root)
        }
        return recorder.measureCounts
    }

    private func settle(_ view: NSView) {
        for _ in 0 ..< 4 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private final class HarnessModel: ObservableObject {
    @Published var selected = 0
    @Published var value = "initial"
}

private final class Recorder: ObservableObject {
    var views: [Int: ProbeView] = [:]
    var tokens: [Int: UUID] = [:]
    var values: [Int: String] = [:]
    var makeCounts: [Int: Int] = [:]
    var measureCounts: [Int: Int] = [:]
}

private struct Harness: View {
    @ObservedObject var model: HarnessModel
    var frozen = true
    var body: some View {
        ZStack {
            ForEach(0 ..< 3) { index in
                if frozen {
                    RetainedTabContent(isActive: model.selected == index, content: StatefulProbe(index: index))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.selected == index {
                    StatefulProbe(index: index).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StatefulProbe(index: index).frame(maxWidth: .infinity, maxHeight: .infinity).hidden()
                }
            }
        }
        .environment(\.probeValue, model.value)
    }
}

private extension EnvironmentValues {
    @Entry var probeValue: String = "missing"
}

private struct StatefulProbe: View {
    let index: Int
    @State private var token = UUID()
    @EnvironmentObject private var recorder: Recorder
    @Environment(\.probeValue) private var value
    var body: some View {
        MeasurementProbe(index: index, recorder: recorder) {
            Probe(index: index, token: token, value: value, recorder: recorder)
        }
    }
}

/// Hidden native views can stop receiving frames while SwiftUI still repeatedly
/// measures their surrounding content. Count proposals, not just frame writes.
private struct MeasurementProbe: Layout {
    let index: Int
    let recorder: Recorder

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        recorder.measureCounts[index, default: 0] += 1
        return subviews[0].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct Probe: NSViewRepresentable {
    let index: Int
    let token: UUID
    let value: String
    let recorder: Recorder

    func makeNSView(context _: Context) -> ProbeView {
        let view = ProbeView()
        recorder.views[index] = view
        recorder.makeCounts[index, default: 0] += 1
        return view
    }

    func updateNSView(_: ProbeView, context _: Context) {
        recorder.tokens[index] = token
        recorder.values[index] = value
    }
}

private final class ProbeView: NSView {
    var resizeCalls = 0
    override var acceptsFirstResponder: Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { resizeCalls += 1 }
        super.setFrameSize(newSize)
    }
}

import AppKit
@testable import Bonsplit
import SwiftUI
import XCTest

final class TabAccessoryTests: XCTestCase {
    @MainActor
    func testAccessoryHookReceivesTabAndPane() {
        let controller = BonsplitController()
        var receivedTabId: TabID?
        var receivedPaneId: PaneID?
        controller.tabAccessory = { tab, paneId in
            receivedTabId = tab.id
            receivedPaneId = paneId
            return AnyView(Image(systemName: "link"))
        }

        let paneId = controller.focusedPaneId!
        let tabId = controller.createTab(title: "Test", inPane: paneId)!
        let tab = controller.tab(tabId)!

        let accessory = controller.tabAccessory?(tab, paneId)
        XCTAssertNotNil(accessory)
        XCTAssertEqual(receivedTabId, tabId)
        XCTAssertEqual(receivedPaneId, paneId)
    }

    @MainActor
    func testHookMayReturnNilPerTab() {
        let controller = BonsplitController()
        controller.tabAccessory = { tab, _ in
            tab.isDirty ? AnyView(Circle()) : nil
        }

        let clean = Tab(title: "Clean", isDirty: false)
        let dirty = Tab(title: "Dirty", isDirty: true)
        XCTAssertNil(controller.tabAccessory?(clean, PaneID()))
        XCTAssertNotNil(controller.tabAccessory?(dirty, PaneID()))
    }

    @MainActor
    func testAccessoryDoesNotChangeTabHeight() {
        let tab = TabItem(title: "Tab")
        let plain = TabItemView(
            tab: tab, isSelected: false, onSelect: {}, onClose: {}
        )
        let decorated = TabItemView(
            tab: tab, isSelected: false, onSelect: {}, onClose: {},
            accessory: AnyView(Text("badge").font(.system(size: 40)))
        )

        let plainHeight = NSHostingView(rootView: plain).fittingSize.height
        let decoratedHeight = NSHostingView(rootView: decorated).fittingSize.height
        XCTAssertEqual(plainHeight, TabBarMetrics.tabHeight)
        XCTAssertEqual(decoratedHeight, plainHeight)
    }
}

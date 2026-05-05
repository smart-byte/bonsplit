import SwiftUI
import UniformTypeIdentifiers

/// Tab bar view with scrollable tabs, drag/drop support, and split buttons
struct TabBarView: View {
    @Environment(BonsplitController.self) private var controller
    @Environment(SplitViewController.self) private var splitViewController

    @Bindable var pane: PaneState
    let isFocused: Bool
    var showSplitButtons: Bool = true

    @State private var dropTargetIndex: Int?
    @State private var dropLifecycle: TabDropLifecycle = .idle
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var canScrollLeft: Bool {
        scrollOffset > 1
    }

    private var canScrollRight: Bool {
        contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth - 1
    }

    /// Whether this tab bar should show full saturation (focused or drag source)
    private var shouldShowFullSaturation: Bool {
        isFocused || splitViewController.dragSourcePaneId == pane.id
    }

    private var isDragging: Bool {
        splitViewController.draggingTab != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tabs with fade overlays
            GeometryReader { containerGeo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TabBarMetrics.tabSpacing) {
                            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index)
                                    .id(tab.id)
                            }

                            // Always keep a small "drop after last tab" target.
                            dropZoneAtEnd
                        }
                        .padding(.horizontal, TabBarMetrics.barPadding)
                        .transaction { tx in
                            tx.animation = nil
                            tx.disablesAnimations = true
                        }
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear
                                    .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                                        scrollOffset = -newFrame.minX
                                        contentWidth = newFrame.width
                                    }
                                    .onAppear {
                                        let frame = contentGeo.frame(in: .named("tabScroll"))
                                        scrollOffset = -frame.minX
                                        contentWidth = frame.width
                                    }
                            }
                        )
                    }
                    .overlay(alignment: .trailing) {
                        let trailingWidth = max(0, containerGeo.size.width - contentWidth)
                        if trailingWidth >= 1 {
                            Color.clear
                                .frame(width: trailingWidth, height: TabBarMetrics.tabHeight)
                                .contentShape(Rectangle())
                                .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
                                    targetIndex: pane.tabs.count,
                                    pane: pane,
                                    controller: splitViewController,
                                    dropTargetIndex: $dropTargetIndex,
                                    dropLifecycle: $dropLifecycle
                                ))
                        }
                    }
                    .coordinateSpace(name: "tabScroll")
                    .onAppear {
                        containerWidth = containerGeo.size.width
                        if let tabId = pane.selectedTabId {
                            proxy.scrollTo(tabId, anchor: .center)
                        }
                    }
                    .onChange(of: containerGeo.size.width) { _, newWidth in
                        // 0.5 pt hysteresis — sub-pixel jitter from
                        // window-edge resize would re-fire body per frame.
                        if abs(newWidth - containerWidth) > 0.5 {
                            containerWidth = newWidth
                        }
                    }
                    .onChange(of: pane.selectedTabId) { _, newTabId in
                        if let tabId = newTabId {
                            withTransaction(Transaction(animation: nil)) {
                                proxy.scrollTo(tabId, anchor: .center)
                            }
                        }
                    }
                }
                .frame(height: TabBarMetrics.barHeight)
                .overlay(fadeOverlays)
            }

            // Split buttons
            if showSplitButtons {
                splitButtons
            }
        }
        .frame(height: TabBarMetrics.barHeight)
        .contentShape(Rectangle())
        .background(tabBarBackground)
        .saturation(shouldShowFullSaturation ? 1.0 : 0)
        .onChange(of: isDragging) { _, newValue in
            if !newValue {
                dropTargetIndex = nil
                dropLifecycle = .idle
            }
        }
    }

    // MARK: - Tab Item

    private func tabItem(for tab: TabItem, at index: Int) -> some View {
        TabDragSource(
            tab: tab,
            sourcePaneId: pane.id,
            controller: splitViewController,
            preview: { AnyView(TabDragPreview(tab: tab)) }
        ) {
            TabItemView(
                tab: tab,
                isSelected: pane.selectedTabId == tab.id,
                onSelect: {
                    withTransaction(Transaction(animation: nil)) {
                        pane.selectTab(tab.id)
                        controller.focusPane(pane.id)
                    }
                },
                onClose: {
                    withTransaction(Transaction(animation: nil)) {
                        _ = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
                    }
                },
                contextMenuContent: contextMenuBuilder(for: tab)
            )
        }
        .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
            targetIndex: index,
            pane: pane,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == index {
                dropIndicator
            }
        }
    }

    /// Returning `nil` when no host hook is installed yields no
    /// `contextMenu` content, preserving the default (no menu) behaviour.
    private func contextMenuBuilder(for tab: TabItem) -> (() -> AnyView)? {
        guard let provider = controller.onTabContextMenu else { return nil }
        let publicTab = Tab(from: tab)
        let paneId = pane.id
        return { provider(publicTab, paneId) }
    }

    // MARK: - Drop Zone at End

    private var dropZoneAtEnd: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 30, height: TabBarMetrics.tabHeight)
            .contentShape(Rectangle())
            .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
                targetIndex: pane.tabs.count,
                pane: pane,
                controller: splitViewController,
                dropTargetIndex: $dropTargetIndex,
                dropLifecycle: $dropLifecycle
            ))
            .overlay(alignment: .leading) {
                if dropTargetIndex == pane.tabs.count {
                    dropIndicator
                }
            }
    }

    // MARK: - Drop Indicator

    private var dropIndicator: some View {
        Capsule()
            .fill(TabBarColors.dropIndicator)
            .frame(width: TabBarMetrics.dropIndicatorWidth, height: TabBarMetrics.dropIndicatorHeight)
            .offset(x: -1)
    }

    // MARK: - Split Buttons

    private var splitButtons: some View {
        HStack(spacing: 4) {
            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .horizontal)
            } label: {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Right")

            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .vertical)
            } label: {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Down")
        }
        .padding(.trailing, 8)
    }

    // MARK: - Fade Overlays

    @ViewBuilder
    private var fadeOverlays: some View {
        let fadeWidth: CGFloat = 24

        HStack(spacing: 0) {
            // Left fade
            LinearGradient(
                colors: [TabBarColors.barBackground, TabBarColors.barBackground.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .opacity(canScrollLeft ? 1 : 0)
            .allowsHitTesting(false)

            Spacer()

            // Right fade
            LinearGradient(
                colors: [TabBarColors.barBackground.opacity(0), TabBarColors.barBackground],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .opacity(canScrollRight ? 1 : 0)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Background

    private var tabBarBackground: some View {
        Rectangle()
            .fill(isFocused ? TabBarColors.barBackground : TabBarColors.barBackground.opacity(0.95))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TabBarColors.separator)
                    .frame(height: 1)
            }
    }
}

enum TabDropLifecycle {
    case idle
    case hovering
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let pane: PaneState
    let controller: SplitViewController
    @Binding var dropTargetIndex: Int?
    @Binding var dropLifecycle: TabDropLifecycle

    func performDrop(info: DropInfo) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                performDrop(info: info)
            }
        }

        // Same-window fast path
        if let draggedTab = controller.draggingTab,
           let sourcePaneId = controller.dragSourcePaneId
        {
            withTransaction(Transaction(animation: nil)) {
                if sourcePaneId == pane.id {
                    guard let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id }) else {
                        return
                    }
                    pane.moveTab(from: sourceIndex, to: targetIndex)
                } else {
                    controller.moveTab(draggedTab, from: sourcePaneId, to: pane.id, atIndex: targetIndex)
                }
            }

            dropLifecycle = .idle
            dropTargetIndex = nil
            controller.draggingTab = nil
            controller.dragSourcePaneId = nil
            return true
        }

        // Foreign drop: source lives in a different controller. Read the
        // payload from the pasteboard and surface to the host.
        return acceptForeignDrop(info: info)
    }

    private func acceptForeignDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.tabTransfer]).first else {
            return false
        }
        let destinationPaneId = pane.id
        let destinationIndex = targetIndex
        let controllerRef = controller
        provider.loadDataRepresentation(forTypeIdentifier: UTType.tabTransfer.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data)
            else { return }
            Task { @MainActor in
                controllerRef.onForeignTabDrop?(
                    transfer.tab,
                    transfer.sourcePaneId,
                    destinationPaneId,
                    destinationIndex
                )
            }
        }
        Task { @MainActor in
            dropLifecycle = .idle
            dropTargetIndex = nil
        }
        return true
    }

    func dropEntered(info _: DropInfo) {
        dropLifecycle = .hovering
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            dropTargetIndex = nil
        } else {
            dropTargetIndex = targetIndex
        }
    }

    func dropExited(info _: DropInfo) {
        dropLifecycle = .idle
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        guard dropLifecycle == .hovering else {
            return DropProposal(operation: .move)
        }
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            dropTargetIndex = nil
        } else if dropTargetIndex != targetIndex {
            dropTargetIndex = targetIndex
        }
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Accept any drop carrying our exported UTI — both same-window
        // and foreign (cross-window) drops qualify here.
        info.hasItemsConforming(to: [.tabTransfer])
    }

    private func shouldSuppressIndicatorForNoopSamePaneDrop() -> Bool {
        guard let draggedTab = controller.draggingTab,
              controller.dragSourcePaneId == pane.id,
              let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id })
        else {
            return false
        }

        return targetIndex == sourceIndex || targetIndex == sourceIndex + 1
    }
}

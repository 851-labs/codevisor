//  Pane-group chrome around the shared native-style tab strip. Group-specific
//  responsibilities stay here: pane lifecycle, cross-group tear-out, the
//  bottom-panel toggle, and its resize handle.

import AppKit
import SwiftUI
import CodevisorCore
import CodevisorUI

struct PaneGroupBar: View {
  @Environment(\.theme) private var theme

  var group: PaneGroupModel
  var dragCoordinator: PaneTabDragCoordinator?
  var chatTitle: ((PaneDescriptorState) -> String)?
  var showsShortcutHints = false
  var onToggle: (() -> Void)?
  var allowsNewChatTab = false
  var dimsForInactiveSplit = false
  var chrome: PaneBarChrome?

  @State private var dragStartHeight: CGFloat?
  @State private var measuredBarFrame: CGRect = .zero
  @State private var measuredStripFrame: CGRect = .zero
  @State private var measuredSlotWidth: CGFloat = PaneTabStripStyle.minTabWidth
  @State private var geometryOwner = UUID()

  enum PaneBarChrome {
    case bottomPanel
    case groupHeader
  }

  private var effectiveChrome: PaneBarChrome {
    chrome ?? (group.placement == .bottom ? .bottomPanel : .groupHeader)
  }

  private var isBottomPanel: Bool { effectiveChrome == .bottomPanel }
  var barHeight: CGFloat { PaneTabStripStyle.barHeight }

  var body: some View {
    HStack(spacing: 8) {
      PaneTabStrip(
        items: tabItems,
        selectedId: group.state.selectedPaneId,
        addButtonHelp: allowsNewChatTab
          ? "New tab (\(ShortcutCatalog.display(for: .newTab)))"
          : "New terminal",
        addButtonAccessibilityLabel: allowsNewChatTab ? "New tab" : "New terminal",
        onSelect: selectPane,
        onClose: { group.closePane(id: $0) },
        onMove: { group.movePane(id: $0, onto: $1) },
        onAdd: addPane,
        isExternalDropTarget: isExternalDropTarget,
        externalDrag: externalDrag,
        onDragStarted: registerDragGeometry,
        onStripGeometryChange: updateStripGeometry,
        onDragSelect: { group.select(id: $0) }
      )

      if isBottomPanel {
        toggleButton
      }
    }
    .padding(.horizontal, 10)
    .frame(height: barHeight)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .overlay {
      Rectangle()
        .fill(theme.windowBackground)
        .opacity(dimsForInactiveSplit ? 0.3 : 0)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
    .overlay(alignment: .top) {
      if isBottomPanel {
        Divider()
        resizeHandle
      }
    }
    .overlay(alignment: .bottom) { Divider() }
    .overlay(alignment: .topLeading) { dropIndicator }
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .global)
    } action: { frame in
      measuredBarFrame = frame
      if let ref = group.dropRef {
        dragCoordinator?.updateBarFrame(frame, for: ref, owner: geometryOwner)
      }
    }
    .onChange(of: dragCoordinator?.active?.paneId) { _, active in
      if active != nil {
        registerDragGeometry()
      }
    }
    .onAppear { registerDragGeometry() }
    .onDisappear {
      if let ref = group.dropRef {
        dragCoordinator?.unregisterBar(owner: geometryOwner, for: ref)
      }
    }
  }

  private var tabItems: [PaneTabStripItem] {
    group.state.panes.enumerated().map { index, pane in
      PaneTabStripItem(
        id: pane.id,
        name: pane.kind == .chat ? (chatTitle?(pane) ?? pane.name) : pane.name,
        kind: pane.kind,
        isAgentOwned: pane.attachOnly,
        pluginId: pane.pluginId,
        pluginPaneType: pane.pluginPaneType,
        pluginIconClient: group.pluginIconClient,
        pluginIconCacheNamespace: group.pluginIconCacheNamespace,
        canClose: group.canClose(id: pane.id),
        shortcutHint: showsShortcutHints && index < 9
          ? ShortcutCatalog.tabSelectionHint(index: index)
          : nil
      )
    }
  }

  private func selectPane(_ id: UUID) {
    group.select(id: id)
    group.focusSelectedPane()
  }

  private func addPane() {
    if allowsNewChatTab {
      group.addNewTabPane()
    } else {
      group.addTerminalPane()
    }
    DispatchQueue.main.async { group.focusSelectedPane() }
  }

  private var externalDrag: PaneTabStripExternalDrag? {
    guard let dragCoordinator, let source = group.dropRef else { return nil }
    return PaneTabStripExternalDrag(
      update: { paneId, location in
        guard dragCoordinator.escapesSourceBar(location, source: source),
          let descriptor = group.state.panes.first(where: { $0.id == paneId })
        else { return false }
        dragCoordinator.dragUpdated(
          paneId: paneId,
          source: source,
          name: descriptor.kind == .chat
            ? (chatTitle?(descriptor) ?? descriptor.name)
            : descriptor.name,
          kind: descriptor.kind,
          isAgentOwned: descriptor.attachOnly,
          sourcePaneCount: group.state.panes.count,
          allowsBottomDrop: descriptor.kind == .terminal,
          location: location
        )
        return true
      },
      cancel: { dragCoordinator.dragCancelled() },
      end: { dragCoordinator.dragEnded() }
    )
  }

  private var isExternalDropTarget: Bool {
    guard let dragCoordinator, let ref = group.dropRef else { return false }
    return dragCoordinator.insertionCaret(for: ref) != nil
  }

  private func updateStripGeometry(_ frame: CGRect, _ slotWidth: CGFloat, _ count: Int) {
    measuredStripFrame = frame
    measuredSlotWidth = slotWidth
    guard let ref = group.dropRef else { return }
    dragCoordinator?.updateStrip(
      minX: frame.minX,
      slotWidth: slotWidth,
      paneCount: count,
      for: ref,
      owner: geometryOwner
    )
  }

  private func registerDragGeometry() {
    guard let dragCoordinator, let ref = group.dropRef else { return }
    dragCoordinator.registerBar(owner: geometryOwner, for: ref)
    if measuredBarFrame != .zero {
      dragCoordinator.updateBarFrame(
        measuredBarFrame,
        for: ref,
        owner: geometryOwner
      )
    }
    if measuredStripFrame != .zero {
      dragCoordinator.updateStrip(
        minX: measuredStripFrame.minX,
        slotWidth: measuredSlotWidth,
        paneCount: group.state.panes.count,
        for: ref,
        owner: geometryOwner
      )
    }
  }

  @ViewBuilder
  private var dropIndicator: some View {
    if let dragCoordinator,
      let ref = group.dropRef,
      let index = dragCoordinator.insertionCaret(for: ref),
      let bar = dragCoordinator.barGeometry(for: ref)
    {
      let stripStart = bar.stripMinX - bar.barFrame.minX
      let stripWidth = bar.slotWidth * CGFloat(max(bar.paneCount, 1))
      let x = min(
        max(stripStart + CGFloat(index) * bar.slotWidth - 1.5, stripStart),
        stripStart + stripWidth - 1.5
      )
      RoundedRectangle(cornerRadius: 1.5)
        .fill(theme.accent)
        .frame(width: 3, height: barHeight - 4)
        .offset(x: x, y: 8)
        .animation(.snappy(duration: 0.15), value: index)
        .allowsHitTesting(false)
    }
  }

  private var toggleButton: some View {
    Button {
      onToggle?()
    } label: {
      Image(systemName: "rectangle.bottomthird.inset.filled")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.textPrimary)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: Circle())
    .help("Toggle bottom panel (\(ShortcutCatalog.display(for: .toggleBottomPanel)))")
    .accessibilityLabel("Toggle bottom panel")
    .accessibilityHint(
      ShortcutCatalog.combo(for: .toggleBottomPanel)
        .map { "Keyboard shortcut: \($0.accessibilityDescription)" } ?? ""
    )
  }

  private var resizeHandle: some View {
    Color.clear
      .frame(height: 6)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .onHover { hovering in
        if hovering {
          NSCursor.resizeUpDown.push()
        } else {
          NSCursor.pop()
        }
      }
      .gesture(resizeGesture)
  }

  private var resizeGesture: some Gesture {
    DragGesture(coordinateSpace: .global)
      .onChanged { value in
        let start = dragStartHeight ?? group.state.height
        dragStartHeight = start
        group.setHeight(start - value.translation.height)
      }
      .onEnded { _ in
        if dragStartHeight != nil {
          group.setHeight(group.state.height, isFinal: true)
        }
        dragStartHeight = nil
      }
  }
}

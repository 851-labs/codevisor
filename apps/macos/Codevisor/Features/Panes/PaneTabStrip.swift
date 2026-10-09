import AppKit
import SwiftUI
import CodevisorCore
import CodevisorUI

/// Sizing and motion for the workspace tab strip.
enum PaneTabStripStyle {
  static let barHeight: CGFloat = 28
  static let minTabWidth: CGFloat = 100
  static let stackSliver: CGFloat = 14
  static let maxStackSlivers = 4
  static let tabMotion: Animation = .snappy(duration: 0.18)
}

/// The presentation and policy needed to render one tab.
struct PaneTabStripItem: Identifiable {
  let id: UUID
  let name: String
  let icon: PaneTabIcon
  let canClose: Bool
  var shortcutHint: String? = nil
}

/// A Chrome-style tab strip. It owns sizing, overflow, scrolling, reordering,
/// close stability, and tab insertion animation; callers own only their data
/// and business actions.
struct PaneTabStrip: View {
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  let items: [PaneTabStripItem]
  let selectedId: UUID?
  let addButtonHelp: String
  let addButtonAccessibilityLabel: String
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  /// A finished drag: the tab and the tab it now sits in front of (nil at
  /// the end). Sent once, on release, so a drag across several tabs is one
  /// move rather than one per tab crossed.
  let onMove: (_ id: UUID, _ successorId: UUID?) -> Void
  let onAdd: () -> Void
  var onRename: ((UUID) -> Void)?

  @State private var draggingId: UUID?
  /// The order shown while a drag is in progress. Nil otherwise.
  @State private var dragOrder: [UUID]?
  @State private var dragOffset: CGFloat = 0
  @State private var dragAdjustment: CGFloat = 0
  @State private var frozenTabWidth: CGFloat?
  @State private var scrollOffset: CGFloat = 0
  @State private var stripFrame: CGRect = .zero
  @State private var stripMaxScroll: CGFloat = 0
  @State private var scrollMonitor: Any?
  @State private var appearanceLedger = TabAppearanceLedger()
  @State private var appearanceTick = 0

  private var itemIds: [UUID] { items.map(\.id) }

  /// The items in on-screen order: the drag's order while one is running.
  private var orderedItems: [PaneTabStripItem] {
    guard let dragOrder else { return items }
    let rank = Dictionary(uniqueKeysWithValues: dragOrder.enumerated().map { ($1, $0) })
    return items.enumerated()
      .sorted { (rank[$0.element.id] ?? $0.offset, $0.offset) < (rank[$1.element.id] ?? $1.offset, $1.offset) }
      .map(\.element)
  }

  var body: some View {
    GeometryReader { geometry in
      let ordered = orderedItems
      let reserved: CGFloat = addButtonDiameter + 4
      let available = max(geometry.size.width - reserved, PaneTabStripStyle.minTabWidth)
      let count = max(ordered.count, 1)
      let fitted = available / CGFloat(count)
      let isOverflowing = fitted < PaneTabStripStyle.minTabWidth
      let tabWidth =
        isOverflowing
        ? PaneTabStripStyle.minTabWidth
        : (frozenTabWidth.map { min($0, available) } ?? fitted)
      let slotWidth = tabWidth
      let maxScroll = max(0, CGFloat(count) * slotWidth - available)
      let offset = min(max(scrollOffset, 0), maxScroll)
      let selectedIndex = ordered.firstIndex { $0.id == selectedId }
      let slots = Self.stripSlots(
        count: count,
        slotWidth: slotWidth,
        available: available,
        offset: offset,
        selected: selectedIndex
      )

      HStack(spacing: 4) {
        stripBody(ordered, slots: slots, tabWidth: tabWidth, slotWidth: slotWidth)
          .frame(width: available, height: PaneTabStripStyle.barHeight, alignment: .topLeading)
          .clipped()
          .onHover { hovering in
            guard !hovering, frozenTabWidth != nil else { return }
            withAnimation(PaneTabStripStyle.tabMotion) { frozenTabWidth = nil }
          }
          .background(trackBackground)
          .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
          } action: { frame in
            stripFrame = frame
            stripMaxScroll = maxScroll
          }

        addButton

        Spacer(minLength: 0)
      }
      .animation(PaneTabStripStyle.tabMotion, value: ordered.map(\.id))
      .onChange(of: selectedId, initial: true) { _, _ in
        scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
      }
      .onChange(of: itemIds) { _, newIds in
        if draggingId == nil {
          scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
        }
        releaseInsertedTabs(newIds)
      }
      .onChange(of: draggingId) { _, dragging in
        guard dragging == nil else { return }
        scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
      }
      .onChange(of: geometry.size.width) { _, _ in
        scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
      }
      .onChange(of: maxScroll, initial: true) { _, value in
        stripMaxScroll = value
      }
      .onChange(of: isOverflowing) { _, overflowing in
        if !overflowing, scrollOffset != 0 {
          scrollOffset = 0
        }
      }
    }
    .frame(height: PaneTabStripStyle.barHeight)
    .onAppear {
      appearanceLedger.knownIds = Set(itemIds)
      appearanceLedger.seeded = true
      installScrollMonitor()
    }
    .onDisappear {
      removeScrollMonitor()
    }
  }

  private var trackBackground: some View {
    Capsule()
      .fill(
        colorScheme == .dark
          ? Color.white.opacity(0.12)
          : Color.black.opacity(0.06)
      )
      .frame(height: PaneTabStripStyle.barHeight)
  }

  private func stripBody(
    _ ordered: [PaneTabStripItem],
    slots: [(x: CGFloat, width: CGFloat)],
    tabWidth: CGFloat,
    slotWidth: CGFloat
  ) -> some View {
    ZStack(alignment: .topLeading) {
      let _ = appearanceTick
      ForEach(Array(ordered.enumerated()), id: \.element.id) { index, item in
        let slot = index < slots.count ? slots[index] : (x: 0, width: tabWidth)
        let isAppearing =
          appearanceLedger.seeded
          && !appearanceLedger.knownIds.contains(item.id)
        PaneTab(
          name: item.name,
          icon: item.icon,
          isSelected: item.id == selectedId,
          isDragging: draggingId == item.id,
          width: slot.width,
          canClose: item.canClose,
          showsTrailingSeparator: index < ordered.count - 1
            && item.id != selectedId
            && ordered[index + 1].id != selectedId
            && draggingId == nil,
          shortcutHint: item.shortcutHint,
          onSelect: { onSelect(item.id) },
          onClose: {
            frozenTabWidth = tabWidth
            onClose(item.id)
          }
        )
        .clipped()
        .scaleEffect(x: isAppearing ? 0.01 : 1, y: 1, anchor: .trailing)
        .offset(x: slot.x + (draggingId == item.id ? dragOffset : 0))
        .zIndex(
          draggingId == item.id
            ? 2
            : (item.id == selectedId ? 1 : 0)
        )
        .transaction { transaction in
          if draggingId == item.id || isAppearing {
            transaction.animation = nil
          }
        }
        .highPriorityGesture(reorderGesture(for: item.id, slotWidth: slotWidth))
        .transition(.asymmetric(insertion: .identity, removal: .opacity))
        .modifier(PaneTabContextMenu(id: item.id, onRename: onRename))
      }
    }
    .frame(height: PaneTabStripStyle.barHeight, alignment: .topLeading)
  }

  private func scrollSelectionIntoView(
    count: Int,
    slotWidth: CGFloat,
    available: CGFloat
  ) {
    guard let selectedId,
      let selected = orderedItems.firstIndex(where: { $0.id == selectedId })
    else { return }
    let maxScroll = max(0, CGFloat(count) * slotWidth - available)
    guard maxScroll > 0 else {
      if scrollOffset != 0 { scrollOffset = 0 }
      return
    }
    let leftReserve =
      PaneTabStripStyle.stackSliver
      * CGFloat(min(selected, PaneTabStripStyle.maxStackSlivers))
    let rightReserve =
      PaneTabStripStyle.stackSliver
      * CGFloat(min(count - 1 - selected, PaneTabStripStyle.maxStackSlivers))
    let upper = CGFloat(selected) * slotWidth - leftReserve
    let lower = CGFloat(selected + 1) * slotWidth - available + rightReserve
    var target = min(max(scrollOffset, lower), upper)
    target = min(max(target, 0), maxScroll)
    guard abs(target - scrollOffset) > 0.5 else { return }
    withAnimation(PaneTabStripStyle.tabMotion) { scrollOffset = target }
  }

  /// The dragged tab follows the pointer; its neighbours slide aside as it
  /// crosses their midpoints. Nothing is saved until release.
  private func reorderGesture(for id: UUID, slotWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .global)
      .onChanged { value in
        if draggingId != id {
          draggingId = id
          dragOrder = itemIds
          dragAdjustment = 0
          if selectedId != id {
            onSelect(id)
          }
        }

        var order = dragOrder ?? itemIds
        var offset = value.translation.width + dragAdjustment
        while offset > slotWidth / 2,
          let next = Self.neighborId(of: id, direction: 1, in: order)
        {
          Self.move(id, onto: next, in: &order)
          dragAdjustment -= slotWidth
          offset -= slotWidth
        }
        while offset < -slotWidth / 2,
          let previous = Self.neighborId(of: id, direction: -1, in: order)
        {
          Self.move(id, onto: previous, in: &order)
          dragAdjustment += slotWidth
          offset += slotWidth
        }
        dragOrder = order
        if let index = order.firstIndex(of: id) {
          let minOffset = -CGFloat(index) * slotWidth
          let maxOffset = CGFloat(order.count - 1 - index) * slotWidth
          offset = min(max(offset, minOffset), maxOffset)
        }
        dragOffset = offset
      }
      .onEnded { _ in
        guard draggingId == id else { return }
        let order = dragOrder ?? itemIds
        withAnimation(PaneTabStripStyle.tabMotion) {
          if order != itemIds, let index = order.firstIndex(of: id) {
            onMove(id, order.indices.contains(index + 1) ? order[index + 1] : nil)
          }
          dragOffset = 0
          draggingId = nil
          dragOrder = nil
          dragAdjustment = 0
        }
      }
  }

  private func releaseInsertedTabs(_ newIds: [UUID]) {
    let ledger = appearanceLedger
    let current = Set(newIds)
    guard ledger.seeded else {
      ledger.knownIds = current
      ledger.seeded = true
      return
    }
    let added = current.subtracting(ledger.knownIds)
    ledger.knownIds.formIntersection(current)
    guard !added.isEmpty else { return }
    DispatchQueue.main.async {
      ledger.knownIds.formUnion(added)
      withAnimation(PaneTabStripStyle.tabMotion) { appearanceTick += 1 }
    }
  }

  private var addButtonDiameter: CGFloat { 26 }

  private var addButton: some View {
    Button {
      frozenTabWidth = nil
      onAdd()
    } label: {
      Image(systemName: "plus")
        .font(.system(size: Typography.IconSize.chrome, weight: .medium))
        .foregroundStyle(theme.textPrimary)
        .frame(width: addButtonDiameter, height: addButtonDiameter)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: Circle())
    .help(addButtonHelp)
    .accessibilityLabel(addButtonAccessibilityLabel)
  }

  private func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
      handleStripScroll(event)
    }
  }

  private func removeScrollMonitor() {
    if let scrollMonitor {
      NSEvent.removeMonitor(scrollMonitor)
    }
    scrollMonitor = nil
  }

  private func handleStripScroll(_ event: NSEvent) -> NSEvent? {
    guard stripMaxScroll > 0,
      let window = event.window,
      window.isKeyWindow
    else { return event }
    let location = CGPoint(
      x: event.locationInWindow.x,
      y: window.frame.height - event.locationInWindow.y
    )
    guard stripFrame.contains(location) else { return event }
    let dx = event.scrollingDeltaX
    let dy = event.scrollingDeltaY
    let delta = abs(dx) >= abs(dy) ? dx : dy
    guard delta != 0 else { return event }
    scrollOffset = min(max(min(scrollOffset, stripMaxScroll) - delta, 0), stripMaxScroll)
    return nil
  }
}

extension PaneTabStrip {
  /// Reconstructs NSTabBar-style edge stacking. The selected tab remains at
  /// full width and pins above the tabs folded under either edge.
  static func stripSlots(
    count: Int,
    slotWidth: CGFloat,
    available: CGFloat,
    offset: CGFloat,
    selected: Int?
  ) -> [(x: CGFloat, width: CGFloat)] {
    var xs: [CGFloat] = []
    xs.reserveCapacity(count)
    for index in 0..<count {
      let raw = CGFloat(index) * slotWidth - offset
      if index == selected {
        let leftPin =
          PaneTabStripStyle.stackSliver
          * CGFloat(min(index, PaneTabStripStyle.maxStackSlivers))
        let rightPin =
          available - slotWidth
          - PaneTabStripStyle.stackSliver
          * CGFloat(min(count - 1 - index, PaneTabStripStyle.maxStackSlivers))
        xs.append(min(max(raw, leftPin), max(leftPin, rightPin)))
      } else {
        let leftMin =
          PaneTabStripStyle.stackSliver
          * CGFloat(min(index, PaneTabStripStyle.maxStackSlivers))
        let rightCap =
          available - PaneTabStripStyle.stackSliver
          * CGFloat(min(count - index, PaneTabStripStyle.maxStackSlivers))
        xs.append(min(max(raw, leftMin), max(leftMin, rightCap)))
      }
    }
    if let selected, count > 0 {
      for index in 0..<selected {
        xs[index] = min(xs[index], xs[selected])
      }
      for index in (selected + 1)..<count {
        xs[index] = max(xs[index], xs[selected])
      }
    }
    var slots: [(x: CGFloat, width: CGFloat)] = []
    slots.reserveCapacity(count)
    for index in 0..<count {
      if index == selected {
        slots.append((x: xs[index], width: slotWidth))
        continue
      }
      let next = index + 1 < count ? xs[index + 1] : available
      slots.append((x: xs[index], width: max(1, min(slotWidth, next - xs[index]))))
    }
    return slots
  }

  private static func neighborId(
    of id: UUID,
    direction: Int,
    in order: [UUID]
  ) -> UUID? {
    guard let index = order.firstIndex(of: id) else { return nil }
    let neighbor = index + direction
    guard order.indices.contains(neighbor) else { return nil }
    return order[neighbor]
  }

  private static func move(_ id: UUID, onto targetId: UUID, in order: inout [UUID]) {
    guard id != targetId,
      let source = order.firstIndex(of: id),
      let target = order.firstIndex(of: targetId)
    else { return }
    let moved = order.remove(at: source)
    order.insert(moved, at: target)
  }
}

private final class TabAppearanceLedger {
  var knownIds: Set<UUID> = []
  var seeded = false
}

private struct PaneTabContextMenu: ViewModifier {
  let id: UUID
  let onRename: ((UUID) -> Void)?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let onRename {
      content.contextMenu {
        Button {
          onRename(id)
        } label: {
          Label("Rename", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
      }
    } else {
      content
    }
  }
}

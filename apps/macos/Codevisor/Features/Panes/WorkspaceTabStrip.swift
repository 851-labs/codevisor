import CodevisorCore
import SwiftUI

/// One tab of the strip.
struct WorkspaceTabStripItem: Identifiable, Equatable {
  enum Icon: Equatable {
    case symbol(String)
    case image(NSImage)
    /// A chat's harness, as the sidebar shows it.
    case harness(String)
  }

  let id: UUID
  let title: String
  let icon: Icon
  let isSelected: Bool
  let isClosable: Bool
}

/// The workspace's tab bar in the window's toolbar row: plain text tabs of
/// one fixed width, so a title loading or a tab opening never shifts the
/// others; a subtle fill on the selected one; a close button on hover
/// (never on the agent's own chat); horizontal scrolling with edge fades
/// once the tabs no longer fit, with the selected tab kept in view.
///
/// Dragging a tab moves it live: the tab follows the pointer and the others
/// slide aside as it passes them. The new order is committed once, on
/// release.
struct WorkspaceTabStrip<NewTab: View>: View {
  typealias Item = WorkspaceTabStripItem

  let items: [Item]
  let select: (UUID) -> Void
  let close: (UUID) -> Void
  /// Closes every closable tab except this one.
  let closeOthers: (UUID) -> Void
  /// Moves a tab so it lands at this index of `items`.
  let move: (UUID, Int) -> Void
  /// The `+` after the last tab.
  @ViewBuilder let newTab: NewTab

  @State private var hovered: UUID?
  @State private var leadingHidden = false
  @State private var trailingHidden = false
  @State private var frames: [UUID: CGRect] = [:]
  @State private var drag: Drag?
  /// The order shown while a drag is live, and after release until the
  /// moved order arrives, so the bar never snaps back in between.
  @State private var previewOrder: [UUID]?

  /// A tab being dragged: where every tab sat when it began, and how far
  /// the pointer has gone since.
  private struct Drag {
    let id: UUID
    let slots: [UUID: CGRect]
    var translation: CGFloat
  }

  static var tabWidth: CGFloat { 168 }
  private static var spacing: CGFloat { 2 }
  private var fadeWidth: CGFloat { 24 }
  private var reorderAnimation: Animation { .snappy(duration: 0.2) }

  private var displayed: [Item] {
    guard let previewOrder else { return items }
    let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let shown = previewOrder.compactMap { byId[$0] }
    // A tab opened or closed mid-drag ends the preview's authority.
    return shown.count == items.count ? shown : items
  }

  /// The tabs take their natural width while they fit, so `+` sits right
  /// after the last tab; once they don't, they scroll and `+` stays put at
  /// the strip's end.
  var body: some View {
    HStack(spacing: 4) {
      ViewThatFits(in: .horizontal) {
        tabRow
        scrollingTabs
      }
      newTab
    }
    .frame(height: 28)
    .onChange(of: items.map(\.id)) { _, _ in
      if drag == nil { previewOrder = nil }
    }
  }

  private var tabRow: some View {
    HStack(spacing: Self.spacing) {
      ForEach(displayed) { item in
        tab(item)
          .id(item.id)
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            frames[item.id] = $0
          }
          .offset(x: dragOffset(of: item))
          .zIndex(drag?.id == item.id ? 1 : 0)
          // The dragged tab stays under the pointer; only the others glide.
          .transaction { if drag?.id == item.id { $0.animation = nil } }
          .gesture(reorder(item))
      }
    }
    .padding(.horizontal, 2)
  }

  private var scrollingTabs: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        tabRow
          .frame(maxHeight: .infinity)
          // The gaps between tabs drag the window like the rest of the
          // toolbar; scroll views otherwise swallow the mouse.
          .background(WindowDragRegion())
      }
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      .onScrollGeometryChange(for: EdgeVisibility.self) { geometry in
        EdgeVisibility(
          leading: geometry.contentOffset.x > 0.5,
          trailing: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 0.5)
      } action: { _, edges in
        leadingHidden = edges.leading
        trailingHidden = edges.trailing
      }
      .mask(fadeMask)
      .onChange(of: items.first(where: \.isSelected)?.id, initial: true) { _, selected in
        guard let selected, drag == nil else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected) }
      }
    }
  }

  private struct EdgeVisibility: Equatable {
    var leading: Bool
    var trailing: Bool
  }

  /// Fades only the edges that actually hide tabs, so a fully scrolled edge
  /// stays crisp.
  private var fadeMask: some View {
    HStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
        .frame(width: leadingHidden ? fadeWidth : 0)
      Rectangle()
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: trailingHidden ? fadeWidth : 0)
    }
  }

  // MARK: - Reordering

  /// How far the dragged tab sits from its current slot: wherever the
  /// pointer has carried it.
  private func dragOffset(of item: Item) -> CGFloat {
    guard let drag, drag.id == item.id, let start = drag.slots[item.id],
      let index = displayed.firstIndex(where: { $0.id == item.id })
    else { return 0 }
    let slots = drag.slots.values.map(\.minX).sorted()
    guard slots.indices.contains(index) else { return 0 }
    return start.minX + drag.translation - slots[index]
  }

  /// A press selects at once; past a small threshold it becomes a drag, so
  /// a click never moves a tab and the tab never fights the window drag.
  private func reorder(_ item: Item) -> some Gesture {
    // Window coordinates: the strip may scroll under the pointer mid-drag.
    DragGesture(minimumDistance: 4, coordinateSpace: .global)
      .onChanged { value in
        if drag?.id != item.id {
          drag = Drag(id: item.id, slots: frames, translation: 0)
          previewOrder = items.map(\.id)
          select(item.id)
        }
        drag?.translation = value.translation.width
        guard let drag, let start = drag.slots[item.id] else { return }
        // Tabs share one width, so the tabs whose middles the dragged tab's
        // middle has passed are exactly the ones that go before it.
        let center = start.midX + value.translation.width
        var order = items.map(\.id).filter { $0 != item.id }
        let index = order.filter { drag.slots[$0].map { $0.midX < center } ?? false }.count
        order.insert(item.id, at: index)
        if order != previewOrder {
          withAnimation(reorderAnimation) { previewOrder = order }
        }
      }
      .onEnded { _ in
        let index = previewOrder?.firstIndex(of: item.id)
        withAnimation(reorderAnimation) { drag = nil }
        if let index, index != items.firstIndex(where: { $0.id == item.id }) {
          move(item.id, index)
        } else {
          previewOrder = nil
        }
      }
  }

  // MARK: - Tabs

  private func tab(_ item: Item) -> some View {
    let isDragged = drag?.id == item.id
    let showsClose = item.isClosable && (hovered == item.id || item.isSelected) && drag == nil
    return HStack(spacing: 6) {
      icon(item.icon)
      Text(item.title)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(item.isSelected ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if item.isClosable {
        Button {
          close(item.id)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(showsClose ? 1 : 0)
        .help("Close Tab")
        .accessibilityLabel("Close \(item.title)")
      }
    }
    .font(.system(size: 12))
    .padding(.leading, 8)
    .padding(.trailing, item.isClosable ? 4 : 8)
    .frame(width: Self.tabWidth, height: 26)
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(.primary.opacity(item.isSelected || isDragged ? 0.1 : hovered == item.id && drag == nil ? 0.05 : 0))
        .shadow(color: .black.opacity(isDragged ? 0.25 : 0), radius: 6, y: 2)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
    .onTapGesture { select(item.id) }
    .contextMenu {
      if item.isClosable {
        Button("Close Tab") { close(item.id) }
      }
      Button("Close Other Tabs") { closeOthers(item.id) }
        .disabled(!items.contains { $0.id != item.id && $0.isClosable })
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { select(item.id) }
    .accessibilityAction(named: "Move Left") { moveBy(item, -1) }
    .accessibilityAction(named: "Move Right") { moveBy(item, 1) }
  }

  private func moveBy(_ item: Item, _ offset: Int) {
    guard let index = items.firstIndex(where: { $0.id == item.id }), items.indices.contains(index + offset)
    else { return }
    move(item.id, index + offset)
  }

  @ViewBuilder
  private func icon(_ icon: Item.Icon) -> some View {
    switch icon {
    case let .symbol(name):
      Image(systemName: name).foregroundStyle(.secondary).frame(width: 14)
    case let .image(image):
      Image(nsImage: image).resizable().scaledToFit().frame(width: 14, height: 14)
    case let .harness(harnessId):
      HarnessIcon(harnessId: harnessId, fallbackSymbolName: "text.bubble", size: 12)
        .foregroundStyle(.secondary)
        .frame(width: 14)
    }
  }
}

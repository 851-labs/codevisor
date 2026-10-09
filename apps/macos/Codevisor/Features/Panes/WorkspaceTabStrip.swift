import CodevisorCore
import SwiftUI

/// One tab of the strip.
struct WorkspaceTabStripItem: Identifiable, Equatable {
  enum Icon: Equatable {
    case symbol(String)
    case image(NSImage)
  }

  enum Kind: Equatable {
    case tab
    /// A subagent's tab group, as its chip: click to collapse or expand.
    case group(status: AgentStatus, collapsed: Bool)
  }

  let id: UUID
  let title: String
  let icon: Icon
  let isSelected: Bool
  let isClosable: Bool
  var kind: Kind = .tab
  /// The workspace the tab belongs to (its group's, inside a group).
  var workspaceId: UUID?
  /// The group's color: on its chip, and under each of its tabs.
  var groupColor: Color?
  /// Whether it can be dragged within the bar: top-level tabs and chips.
  var isMovable = true
}

/// The workspace's tab bar in the window's toolbar row: plain text tabs, a
/// subtle fill on the selected one, a close button on hover (never on the
/// agent's own chat), horizontal scrolling with edge fades once the tabs no
/// longer fit, and the selected tab kept in view. Tabs drag to reorder; the
/// order is committed once, on release.
struct WorkspaceTabStrip<NewTab: View>: View {
  typealias Item = WorkspaceTabStripItem

  let items: [Item]
  let select: (UUID) -> Void
  let close: (UUID) -> Void
  /// Closes every closable tab except this one.
  let closeOthers: (UUID) -> Void
  /// Moves a tab so it lands at this index of `items`.
  let move: (UUID, Int) -> Void
  /// A group chip was clicked: collapse or expand it.
  let toggleGroup: (UUID) -> Void
  /// Makes a subagent's group an independent, top-level agent.
  let promoteGroup: (UUID) -> Void
  let archiveGroup: (UUID) -> Void
  /// The `+` after the last tab.
  @ViewBuilder let newTab: NewTab

  @State private var hovered: UUID?
  @State private var leadingHidden = false
  @State private var trailingHidden = false
  @State private var frames: [UUID: CGRect] = [:]
  @State private var dragging: UUID?
  @State private var dragOffset: CGFloat = 0

  /// Tabs size to their titles, up to this, like Safari's compact tabs.
  private var titleWidth: CGFloat { 180 }
  private var fadeWidth: CGFloat { 24 }

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
  }

  private var tabRow: some View {
    HStack(spacing: 2) {
      ForEach(items) { item in
        entry(item)
          .id(item.id)
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            frames[item.id] = $0
          }
          .offset(x: dragging == item.id ? dragOffset : 0)
          .zIndex(dragging == item.id ? 1 : 0)
          .gesture(reorder(item), isEnabled: item.isMovable)
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
        guard let selected else { return }
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

  /// A press selects at once; past a small threshold it becomes a drag, so
  /// a click never moves a tab and the tab never fights the window drag.
  private func reorder(_ item: Item) -> some Gesture {
    // Window coordinates: the strip may scroll under the pointer mid-drag,
    // and each tab's live frame follows it there.
    DragGesture(minimumDistance: 4, coordinateSpace: .global)
      .onChanged { value in
        if dragging != item.id {
          dragging = item.id
          select(item.id)
        }
        dragOffset = value.translation.width
      }
      .onEnded { value in
        defer {
          dragging = nil
          dragOffset = 0
        }
        let others = items.filter { $0.id != item.id }
        let index =
          others.firstIndex { other in
            frames[other.id].map { value.location.x < $0.midX } ?? false
          } ?? others.count
        guard index != items.firstIndex(where: { $0.id == item.id }) else { return }
        move(item.id, index)
      }
  }

  @ViewBuilder
  private func entry(_ item: Item) -> some View {
    switch item.kind {
    case .tab: tab(item)
    case let .group(status, collapsed): chip(item, status: status, collapsed: collapsed)
    }
  }

  /// A subagent's group: its color, a status dot, and its name. Collapsed,
  /// it stands in for the group's tabs.
  private func chip(_ item: Item, status: AgentStatus, collapsed: Bool) -> some View {
    let color = item.groupColor ?? .accentColor
    return HStack(spacing: 5) {
      Circle()
        .fill(status.isBlocked ? Color.orange : status == .working ? color : color.opacity(0.5))
        .frame(width: 6, height: 6)
      Text(item.title)
        .lineLimit(1)
        .frame(maxWidth: 140, alignment: .leading)
      if collapsed {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.primary)
    .padding(.horizontal, 8)
    .frame(height: 22)
    .fixedSize(horizontal: true, vertical: false)
    .background(Capsule().fill(color.opacity(dragging == item.id ? 0.35 : 0.22)))
    .contentShape(Capsule())
    .onTapGesture { toggleGroup(item.id) }
    .contextMenu {
      Button(collapsed ? "Expand Group" : "Collapse Group") { toggleGroup(item.id) }
      Divider()
      Button("Move to Sidebar") { promoteGroup(item.id) }
      Button("Archive") { archiveGroup(item.id) }
    }
    .help(collapsed ? "Show \(item.title)'s tabs" : "Hide \(item.title)'s tabs")
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(item.title) subagent, \(collapsed ? "collapsed" : "expanded")")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { toggleGroup(item.id) }
  }

  private func tab(_ item: Item) -> some View {
    let showsClose = item.isClosable && (hovered == item.id || item.isSelected)
    return HStack(spacing: 6) {
      icon(item.icon)
      Text(item.title)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(item.isSelected ? .primary : .secondary)
        .frame(maxWidth: titleWidth, alignment: .leading)
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
    .frame(height: 26)
    .fixedSize(horizontal: true, vertical: false)
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(.primary.opacity(item.isSelected || dragging == item.id ? 0.1 : hovered == item.id ? 0.05 : 0))
    }
    // A group's tabs share its color underneath, like Chrome's tab groups.
    .overlay(alignment: .bottom) {
      if let color = item.groupColor {
        Capsule().fill(color).frame(height: 2).padding(.horizontal, 6)
      }
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
  }

  @ViewBuilder
  private func icon(_ icon: Item.Icon) -> some View {
    switch icon {
    case let .symbol(name):
      Image(systemName: name).foregroundStyle(.secondary).frame(width: 14)
    case let .image(image):
      Image(nsImage: image).resizable().scaledToFit().frame(width: 14, height: 14)
    }
  }
}

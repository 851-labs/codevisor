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

  enum Kind: Equatable {
    case tab
    /// A subagent's tab group, as its label: the subagent's own chat tab,
    /// which leads its other tabs and collapses them.
    case group(status: AgentStatus, collapsed: Bool, otherTabs: Int, homeTabId: UUID?)
  }

  let id: UUID
  let title: String
  let icon: Icon
  let isSelected: Bool
  let isClosable: Bool
  var kind: Kind = .tab
  /// The workspace the tab belongs to (its group's, inside a group).
  var workspaceId: UUID?
  /// Whether it can be dragged within the bar: top-level tabs and labels.
  var isMovable = true
}

/// The workspace's tab bar in the window's toolbar row: plain text tabs, a
/// subtle fill on the selected one, a close button on hover (never on the
/// agent's own chat), horizontal scrolling with edge fades once the tabs no
/// longer fit, and the selected tab kept in view. Tabs drag to reorder; the
/// order is committed once, on release.
///
/// A subagent's tabs sit together in one quiet container led by its own
/// chat's tab, which shows the subagent's status (its harness at rest) and
/// a chevron that collapses the rest. Collapsed, the container is just that
/// tab and how many it hides.
struct WorkspaceTabStrip<NewTab: View>: View {
  typealias Item = WorkspaceTabStripItem

  let items: [Item]
  let select: (UUID) -> Void
  let close: (UUID) -> Void
  /// Closes every closable tab except this one.
  let closeOthers: (UUID) -> Void
  /// Moves a tab so it lands at this index of `items`.
  let move: (UUID, Int) -> Void
  /// A group's label was clicked: collapse or expand it.
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

  /// A run of the bar: a tab of its own, or a group's label and its tabs.
  private enum Segment: Identifiable {
    case tab(Item)
    case group(label: Item, tabs: [Item])

    var id: UUID {
      switch self {
      case let .tab(item): item.id
      case let .group(label, _): label.id
      }
    }
  }

  /// The items as the bar draws them: each label gathers the tabs of its
  /// workspace that follow it.
  private var segments: [Segment] {
    var result: [Segment] = []
    var index = 0
    while index < items.count {
      let item = items[index]
      guard case .group = item.kind else {
        result.append(.tab(item))
        index += 1
        continue
      }
      var tabs: [Item] = []
      var next = index + 1
      while next < items.count, case .tab = items[next].kind, items[next].workspaceId == item.workspaceId {
        tabs.append(items[next])
        next += 1
      }
      result.append(.group(label: item, tabs: tabs))
      index = next
    }
    return result
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
  }

  private var tabRow: some View {
    HStack(spacing: 2) {
      ForEach(segments) { segment in
        Group {
          switch segment {
          case let .tab(item):
            tab(item)
              .modifier(TrackedFrame(id: item.id, frames: $frames))
              .gesture(reorder(item), isEnabled: item.isMovable)
          case let .group(label, tabs):
            group(label, tabs: tabs)
          }
        }
        .offset(x: dragging == segment.id ? dragOffset : 0)
        .zIndex(dragging == segment.id ? 1 : 0)
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

  // MARK: - Groups

  /// A subagent's group: its label, then its tabs, in one container.
  private func group(_ label: Item, tabs: [Item]) -> some View {
    let collapsed = if case let .group(_, collapsed, _, _) = label.kind { collapsed } else { false }
    return HStack(spacing: 2) {
      groupLabel(label)
        .modifier(TrackedFrame(id: label.id, frames: $frames))
        .gesture(reorder(label), isEnabled: label.isMovable)
      if !collapsed, !tabs.isEmpty {
        Rectangle()
          .fill(.primary.opacity(0.12))
          .frame(width: 1, height: 14)
          .padding(.horizontal, 2)
        ForEach(tabs) { item in
          tab(item).modifier(TrackedFrame(id: item.id, frames: $frames))
        }
      }
    }
    .padding(1)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.primary.opacity(dragging == label.id ? 0.09 : 0.045))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
    }
  }

  /// The subagent's chat tab: its status (its harness at rest), its name,
  /// and the chevron that shows or hides its other tabs -- with their count
  /// while hidden.
  @ViewBuilder
  private func groupLabel(_ item: Item) -> some View {
    if case let .group(status, collapsed, otherTabs, homeTabId) = item.kind {
      HStack(spacing: 6) {
        groupStatus(status, icon: item.icon)
        Text(item.title)
          .lineLimit(1)
          .foregroundStyle(item.isSelected ? .primary : .secondary)
          .frame(maxWidth: titleWidth, alignment: .leading)
        if otherTabs > 0 {
          Button {
            toggleGroup(item.id)
          } label: {
            HStack(spacing: 3) {
              if collapsed { Text("\(otherTabs)").monospacedDigit() }
              Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 180))
            }
            .foregroundStyle(.tertiary)
            .frame(minWidth: 16, minHeight: 16)
            .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .help(collapsed ? "Show \(otherTabs) More Tab\(otherTabs == 1 ? "" : "s")" : "Hide Tabs")
          .accessibilityLabel(collapsed ? "Show \(item.title)'s tabs" : "Hide \(item.title)'s tabs")
        }
      }
      .font(.system(size: 12))
      .padding(.leading, 8)
      .padding(.trailing, otherTabs > 0 ? 4 : 8)
      .frame(height: 26)
      .fixedSize(horizontal: true, vertical: false)
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(.primary.opacity(item.isSelected ? 0.1 : hovered == item.id ? 0.05 : 0))
      }
      .contentShape(Rectangle())
      .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
      .onTapGesture { if let homeTabId { select(homeTabId) } }
      .contextMenu {
        if otherTabs > 0 {
          Button(collapsed ? "Show Tabs" : "Hide Tabs") { toggleGroup(item.id) }
          Divider()
        }
        Button("Move to Sidebar") { promoteGroup(item.id) }
        Button("Archive") { archiveGroup(item.id) }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(item.title), subagent")
      .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { if let homeTabId { select(homeTabId) } }
    }
  }

  /// The same marks the sidebar gives a chat: working, waiting, error and
  /// unread replace the harness icon.
  @ViewBuilder
  private func groupStatus(_ status: AgentStatus, icon: Item.Icon) -> some View {
    switch status {
    case .working: AgentActivityIndicator().frame(width: 14, height: 14)
    case .waiting: ActionRequiredIndicator(color: .red).frame(width: 14, height: 14)
    case .errored: ErrorUnreadBadge(color: .red).frame(width: 14, height: 14)
    case .unread: UnreadBadge(color: .accentColor).frame(width: 14, height: 14)
    case .idle: self.icon(icon)
    }
  }

  // MARK: - Tabs

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
    case let .harness(harnessId):
      HarnessIcon(harnessId: harnessId, fallbackSymbolName: "text.bubble", size: 12)
        .foregroundStyle(.secondary)
        .frame(width: 14)
    }
  }
}

/// Records a tab's frame in window coordinates, where a drag measures where
/// it lands, and names it for scrolling into view.
private struct TrackedFrame: ViewModifier {
  let id: UUID
  @Binding var frames: [UUID: CGRect]

  func body(content: Content) -> some View {
    content
      .id(id)
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        frames[id] = $0
      }
  }
}

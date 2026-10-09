import CodevisorCore
import SwiftUI

/// The workspace's tab bar in the window's toolbar row: plain text tabs, a
/// subtle fill on the selected one, a close button on hover (never on the
/// agent's own chat), horizontal scrolling with edge fades once the tabs no
/// longer fit, and the selected tab kept in view.
struct WorkspaceTabStrip: View {
  struct Item: Identifiable, Equatable {
    enum Icon: Equatable {
      case symbol(String)
      case image(NSImage)
    }

    let id: UUID
    let title: String
    let icon: Icon
    let isSelected: Bool
    let isClosable: Bool
  }

  let items: [Item]
  let select: (UUID) -> Void
  let close: (UUID) -> Void
  let newTab: () -> Void

  @State private var hovered: UUID?
  @State private var leadingHidden = false
  @State private var trailingHidden = false

  /// Tabs size to their titles, up to this, like Safari's compact tabs.
  private static let titleWidth: CGFloat = 180
  private static let fadeWidth: CGFloat = 24

  /// The tabs take their natural width while they fit, so `+` sits right
  /// after the last tab; once they don't, they scroll and `+` stays put at
  /// the strip's end.
  var body: some View {
    HStack(spacing: 4) {
      ViewThatFits(in: .horizontal) {
        tabRow
        scrollingTabs
      }
      Button(action: newTab) {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .medium))
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help("New Tab (⌘T)")
      .accessibilityLabel("New Tab")
    }
    .frame(height: 28)
  }

  private var tabRow: some View {
    HStack(spacing: 2) {
      ForEach(items) { item in
        tab(item).id(item.id)
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
        .frame(width: leadingHidden ? Self.fadeWidth : 0)
      Rectangle()
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: trailingHidden ? Self.fadeWidth : 0)
    }
  }

  private func tab(_ item: Item) -> some View {
    let showsClose = item.isClosable && (hovered == item.id || item.isSelected)
    return HStack(spacing: 6) {
      icon(item.icon)
      Text(item.title)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(item.isSelected ? .primary : .secondary)
        .frame(maxWidth: Self.titleWidth, alignment: .leading)
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
        .fill(.primary.opacity(item.isSelected ? 0.1 : hovered == item.id ? 0.05 : 0))
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
    .onTapGesture { select(item.id) }
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

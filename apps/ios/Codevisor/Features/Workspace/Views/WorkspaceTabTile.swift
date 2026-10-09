import CodevisorCore
import SwiftUI

/// A tab's picture: its last snapshot, or its icon until it has one. The
/// same view is the grid tile and the layer zooming in and out of it, so
/// the zoom moves one picture rather than cross-fading two.
struct WorkspaceTabPreview: View {
  let tab: HomeSidebarTabRow
  let serverId: String

  var body: some View {
    if let image = PaneSnapshotCache.shared.image(for: tab.id) {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
    } else {
      Rectangle()
        .fill(.background.secondary)
        .overlay {
          HomeSidebarTabIcon(row: tab, serverId: serverId, size: 34)
            .foregroundStyle(.secondary)
        }
    }
  }
}

/// One tab in the overview: its picture with a close button, and its icon
/// and title underneath, as Safari's tab grid draws them.
struct WorkspaceTabTile: View {
  let tab: HomeSidebarTabRow
  let serverId: String
  /// Width over height of the tab's screen area, so the picture isn't
  /// cropped differently in the tile than full-size.
  let aspectRatio: CGFloat
  let isSelected: Bool
  /// The agent's own chat has no close button.
  let isClosable: Bool
  /// The zooming layer currently stands in for this tile's picture.
  let isExpanded: Bool
  let onClose: () -> Void
  /// The picture's frame in the grid, for the zoom to land on.
  let onPictureFrame: (CGRect) -> Void

  static let cornerRadius: CGFloat = 16

  var body: some View {
    VStack(spacing: 7) {
      WorkspaceTabPreview(tab: tab, serverId: serverId)
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .opacity(isExpanded ? 0 : 1)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .named(WorkspaceTabGrid.coordinateSpace))
        } action: {
          onPictureFrame($0)
        }
        .overlay {
          RoundedRectangle(cornerRadius: Self.cornerRadius)
            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 3 : 0.5)
            .opacity(isExpanded ? 0 : 1)
        }
        .overlay(alignment: .topTrailing) {
          if isClosable, !isExpanded {
            Button("Close \(tab.title)", systemImage: "xmark", action: onClose)
              .labelStyle(.iconOnly)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(.secondary)
              .frame(width: 24, height: 24)
              .background(.regularMaterial, in: .circle)
              .padding(6)
              // The visible circle is small; the target is the full 44pt.
              .contentShape(.rect.inset(by: -10))
          }
        }
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
      HStack(spacing: 5) {
        HomeSidebarTabIcon(row: tab, serverId: serverId, size: 13)
        Text(tab.title)
          .font(.caption)
          .lineLimit(1)
      }
      .padding(.horizontal, 4)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

import SwiftUI

struct SidebarBotRow: View {
  let title: String
  let systemImage: String
  let isSelected: Bool
  let isHoverEnabled: Bool
  let isExpanded: Bool?
  let onSelect: () -> Void
  let onToggle: () -> Void
  @State private var isHovered = false

  private var showsChevron: Bool { isExpanded != nil && isHovered && isHoverEnabled }

  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
          .opacity(showsChevron ? 0 : 1)
        Button(action: onToggle) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded == true ? 90 : 0))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(showsChevron ? 1 : 0)
        .allowsHitTesting(showsChevron)
        .help(isExpanded == true ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityHidden(true)
      }
      .frame(width: 18)
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .sidebarRowHover(isSelected: isSelected, isEnabled: isHoverEnabled)
    .onHover { isHovered = $0 }
    .onTapGesture(perform: onSelect)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityValue(isExpanded.map { $0 ? "Expanded" : "Collapsed" } ?? "")
    .accessibilityAction(.default, onSelect)
    .accessibilityActions {
      if let isExpanded { Button(isExpanded ? "Collapse" : "Expand", action: onToggle) }
    }
  }
}

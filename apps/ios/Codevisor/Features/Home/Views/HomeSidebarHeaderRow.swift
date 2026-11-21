import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarHeaderRow: View {
  let header: HomeSidebarOutline.Header
  @Binding var isExpanded: Bool
  let isConversation: Bool
  var isFirst = false
  var sectionMenu: HomeSidebarSectionMenu? = nil
  var onNewChat: (() -> Void)? = nil

  var body: some View {
    switch header {
    case let .group(_, heading):
      groupRow(heading)
    default:
      HomeSidebarSectionToggle(title: title, isExpanded: $isExpanded, chevron: isConversation ? .conversation : .system)
        .font(.headline)
        .foregroundStyle(.secondary)
        .frame(minHeight: Self.height - 2 * Self.verticalInset, maxHeight: .infinity, alignment: .bottom)
        .accessibilityAddTraits(.isHeader)
        .contentShape([.contextMenuPreview, .dragPreview], previewShape)
        .contextMenu { sectionMenu }
        .listRowInsets(insets)
        .listRowBackground(listBackground)
        .listRowSeparator(.hidden, edges: isConversation ? .bottom : .all)
    }
  }

  static let height: CGFloat = 40
  private static let verticalInset: CGFloat = 9

  private var insets: EdgeInsets {
    let gap: CGFloat = isFirst ? 0 : (isConversation ? 22 : 18)
    let horizontal: CGFloat = isConversation ? 16 : 20
    return EdgeInsets(
      top: gap + Self.verticalInset, leading: horizontal, bottom: Self.verticalInset, trailing: horizontal)
  }

  private var previewShape: HomeSidebarHeaderPreviewShape {
    HomeSidebarHeaderPreviewShape(horizontal: insets.leading, vertical: Self.verticalInset)
  }

  private var listBackground: Color {
    Color(uiColor: isConversation ? .systemBackground : .systemGroupedBackground)
  }

  private var title: String {
    switch header {
    case .pinned: "Pinned"
    case let .section(section): section.name
    case let .list(title): title
    case let .group(_, heading): heading.title
    }
  }

  private func groupRow(_ heading: SidebarWorkspaceGroup.Heading) -> some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack {
        HomeSidebarGroupLabel(heading: heading, onNewChat: onNewChat)
        Spacer(minLength: 0)
        HomeSidebarDisclosureChevron(isExpanded: isExpanded)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}

nonisolated struct HomeSidebarHeaderPreviewShape: Shape {
  let horizontal: CGFloat
  let vertical: CGFloat

  func path(in rect: CGRect) -> Path {
    let row = rect.insetBy(dx: -horizontal, dy: -vertical)
    return RoundedRectangle(cornerRadius: row.height / 2, style: .continuous).path(in: row)
  }
}

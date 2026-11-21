import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarHeaderRow: View {
  let header: HomeSidebarOutline.Header
  @Binding var isExpanded: Bool
  let isConversation: Bool
  var sectionMenu: HomeSidebarSectionMenu? = nil
  var onNewChat: (() -> Void)? = nil

  var body: some View {
    switch header {
    case let .group(_, heading):
      groupRow(heading)
    default:
      HomeSidebarSectionToggle(title: title, isExpanded: $isExpanded)
        .font(isConversation ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
        .contextMenu { sectionMenu }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
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

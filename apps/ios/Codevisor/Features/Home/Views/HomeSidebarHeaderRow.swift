import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarHeaderRow: View {
  let header: HomeSidebarOutline.Header
  @Binding var isExpanded: Bool
  let isConversation: Bool
  var isFirst = false

  var body: some View {
    switch header {
    case let .group(_, heading):
      groupRow(heading)
    default:
      HomeSidebarSectionToggle(title: title, isExpanded: $isExpanded, chevron: isConversation ? .conversation : .system)
        .font(.headline)
        .foregroundStyle(.secondary)
        .frame(
          minHeight: HomeSidebarHeaderMetrics(isConversation: isConversation).contentHeight, maxHeight: .infinity,
          alignment: .bottom
        )
        .accessibilityAddTraits(.isHeader)
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
        HomeSidebarGroupLabel(heading: heading)
        Spacer(minLength: 0)
        HomeSidebarDisclosureChevron(isExpanded: isExpanded)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}

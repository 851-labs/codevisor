import SwiftUI

struct HomeSidebarCollectionCellContent: View {
  let row: HomeSidebarCollectionRow
  let environment: EnvironmentValues
  let isSelected: Bool
  let isSidebar: Bool
  let select: (UUID) -> Void

  var body: some View {
    if let id = row.selectionID {
      content
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(id) }
    } else {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if isSidebar {
      environmental(row.content.labelStyle(HomeSidebarListLabelStyle()))
    } else {
      environmental(row.content)
    }
  }

  private func environmental(_ content: some View) -> some View {
    content
      .environment(\.backgroundProminence, isSelected ? .increased : .standard)
      .environment(\.self, environment)
  }
}

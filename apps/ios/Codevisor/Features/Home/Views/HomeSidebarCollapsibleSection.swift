import SwiftUI

struct HomeSidebarCollapsibleSection<Content: View>: View {
  let title: String
  @Binding var isExpanded: Bool
  let isConversation: Bool
  @ViewBuilder let content: Content

  var body: some View {
    if isConversation {
      Section {
        if isExpanded { content }
      } header: {
        HomeSidebarSectionToggle(title: title, isExpanded: $isExpanded)
      }
    } else {
      Section(title, isExpanded: $isExpanded) { content }
    }
  }
}

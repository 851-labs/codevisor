import SwiftUI

struct SidebarSelectionReader<Content: View>: View {
  @Binding var selection: SidebarSelection?
  @ViewBuilder let content: (SidebarSelection?) -> Content

  var body: some View {
    content(selection)
  }
}

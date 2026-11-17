import SwiftUI

struct WorkspaceChromeReporter: View {
  let chrome: () -> WorkspaceChrome
  let page: WorkspacePageModel?
  @State private var publisher = UUID()

  var body: some View {
    Color.clear
      .onChange(of: chrome(), initial: true) { _, chrome in page?.publish(chrome, from: publisher) }
      .onDisappear { page?.withdrawChrome(from: publisher) }
  }
}

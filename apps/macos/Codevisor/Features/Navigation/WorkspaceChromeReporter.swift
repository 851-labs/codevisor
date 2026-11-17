import SwiftUI

struct WorkspaceChromeReporter: View {
  let chrome: () -> WorkspaceChrome
  let page: WorkspacePageModel?

  var body: some View {
    Color.clear
      .onChange(of: chrome(), initial: true) { _, chrome in page?.chrome = chrome }
  }
}

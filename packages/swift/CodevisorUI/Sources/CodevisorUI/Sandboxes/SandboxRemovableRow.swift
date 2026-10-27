import CodevisorCore
import SwiftUI

struct SandboxRemovableRow<Content: View>: View {
  let account: ServerSandboxAccount?
  let onRemove: (ServerSandboxAccount) -> Void
  @ViewBuilder let content: Content

  var body: some View {
    if let account {
      #if os(macOS)
        content.contextMenu {
          Button("Remove Account…", role: .destructive) { onRemove(account) }
        }
      #else
        content.swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button("Remove", systemImage: "trash", role: .destructive) { onRemove(account) }
            .labelStyle(.iconOnly)
        }
      #endif
    } else {
      content
    }
  }
}

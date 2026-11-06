import SwiftUI

struct NewChatComposeButton: View {
  let onNewChat: () -> Void
  @FocusedValue(\.newChatComposerFocus) private var composerFocus

  var body: some View {
    Button(action: newChat) {
      Label(ShortcutCatalog.title(for: .newChat), systemImage: "square.and.pencil")
    }
    .labelStyle(.iconOnly)
    .help("\(ShortcutCatalog.title(for: .newChat)) \(ShortcutCatalog.display(for: .newChat))")
  }

  private func newChat() {
    onNewChat()
    composerFocus?.focus()
  }
}

import SwiftUI

struct NewChatComposeButton: View {
  let isSelected: Bool
  let onNewChat: () -> Void
  @FocusedValue(\.newChatComposerFocus) private var composerFocus

  var body: some View {
    Button(action: newChat) {
      Label(ShortcutCatalog.title(for: .newChat), systemImage: "square.and.pencil")
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
    .labelStyle(.iconOnly)
    .help("\(ShortcutCatalog.title(for: .newChat)) \(ShortcutCatalog.display(for: .newChat))")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func newChat() {
    onNewChat()
    composerFocus?.focus()
  }
}

import SwiftUI

extension EnvironmentValues {
  @Entry var composerControlTypingFocus: ComposerControlTypingFocus? = nil
}

extension View {
  /// Composer controls stay reachable even when macOS's all-controls Tab
  /// navigation is off. An explicit focus target also needs an activation
  /// handler: a SwiftUI focus wrapper does not forward Space to its Button.
  func composerKeyboardButton(action: @escaping () -> Void) -> some View {
    modifier(ComposerKeyboardButtonModifier(action: action))
  }
}

private struct ComposerKeyboardButtonModifier: ViewModifier {
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.composerControlTypingFocus) private var typingFocus
  @FocusState private var isFocused: Bool
  @State private var controlID = UUID()

  func body(content: Content) -> some View {
    content
      // Replace the button's intrinsic stop with this explicit one, so
      // enabling all-controls navigation doesn't produce two Tab stops.
      .focusable(false)
      .focusable(isEnabled)
      .focused($isFocused)
      .onChange(of: isFocused) { _, focused in
        typingFocus?.setControlFocused(focused, id: controlID)
      }
      .onDisappear {
        typingFocus?.setControlFocused(false, id: controlID)
      }
      .onKeyPress(keys: [.space, .return], phases: .down) { press in
        guard isEnabled, press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
          return .ignored
        }
        action()
        return .handled
      }
  }
}

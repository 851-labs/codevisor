import SwiftUI

struct SandboxTextInput: View {
  enum Keyboard {
    case text, number, url
  }

  let label: String
  let prompt: String
  @Binding var text: String
  var isSecret = false
  var keyboard = Keyboard.text
  var onCommit: (() -> Void)?
  @FocusState private var isFocused: Bool

  var body: some View {
    #if os(macOS)
      committing(field(label))
    #else
      LabeledContent(label) {
        committing(field(""))
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(keyboardType)
      }
    #endif
  }

  private func committing(_ input: some View) -> some View {
    input
      .focused($isFocused)
      .onSubmit { onCommit?() }
      .onChange(of: isFocused) { wasFocused, focused in
        if wasFocused && !focused { onCommit?() }
      }
  }

  @ViewBuilder
  private func field(_ title: String) -> some View {
    if isSecret {
      SecureField(title, text: $text, prompt: Text(prompt))
        .privacySensitive()
    } else {
      TextField(title, text: $text, prompt: Text(prompt))
    }
  }

  #if os(iOS)
    private var keyboardType: UIKeyboardType {
      switch keyboard {
      case .text: .default
      case .number: .decimalPad
      case .url: .URL
      }
    }
  #endif
}

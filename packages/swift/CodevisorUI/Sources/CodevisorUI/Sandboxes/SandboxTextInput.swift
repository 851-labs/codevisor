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

  var body: some View {
    #if os(macOS)
      field(label)
    #else
      LabeledContent(label) {
        field("")
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(keyboardType)
      }
    #endif
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

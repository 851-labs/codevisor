import SwiftUI

struct ConfigFieldTextInput: View {
  let label: String
  @Binding var text: String
  let prompt: Text?
  let isSecure: Bool

  var body: some View {
    #if os(iOS)
      LabeledContent(label) {
        input(title: "")
          .multilineTextAlignment(.trailing)
      }
    #else
      input(title: label)
    #endif
  }

  @ViewBuilder
  private func input(title: String) -> some View {
    if isSecure {
      SecureField(title, text: $text, prompt: prompt)
    } else {
      TextField(title, text: $text, prompt: prompt)
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
    }
  }
}

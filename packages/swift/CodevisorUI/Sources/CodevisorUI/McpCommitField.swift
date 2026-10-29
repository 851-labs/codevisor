import SwiftUI

struct McpCommitField: View {
  let title: String
  @Binding var text: String
  var prompt: String?
  var isSecure = false
  let onCommit: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    #if os(iOS)
      LabeledContent(title) {
        input.multilineTextAlignment(.trailing)
      }
    #else
      input
    #endif
  }

  private var input: some View {
    field
      .focused($isFocused)
      .onSubmit(onCommit)
      .onChange(of: isFocused) { wasFocused, focused in
        if wasFocused && !focused { onCommit() }
      }
      .autocorrectionDisabled()
      #if os(iOS)
        .textInputAutocapitalization(.never)
      #endif
  }

  @ViewBuilder
  private var field: some View {
    if isSecure {
      SecureField(title, text: $text, prompt: prompt.map { Text($0) })
    } else {
      TextField(title, text: $text, prompt: prompt.map { Text($0) })
    }
  }
}

struct McpFieldError: View {
  let message: String?

  var body: some View {
    if let message {
      Text(message)
        .font(.callout)
        .foregroundStyle(.red)
    }
  }
}

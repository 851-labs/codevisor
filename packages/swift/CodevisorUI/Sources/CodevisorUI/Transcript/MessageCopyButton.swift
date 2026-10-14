import SwiftUI

public struct MessageCopyButton: View {
  let text: String
  var help: String = "Copy message"
  var isRevealed: Bool = true
  @State private var didCopy = false
  @State private var copyCount = 0

  public init(text: String, help: String = "Copy message", isRevealed: Bool = true) {
    self.text = text
    self.help = help
    self.isRevealed = isRevealed
  }

  public var body: some View {
    Button {
      PlatformPasteboard.copy(text)
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        didCopy = true
        copyCount += 1
      }
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        withTransaction(transaction) { didCopy = false }
      }
    } label: {
      Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        .font(.caption)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(HoverIconButtonStyle(shape: .roundedRectangle))
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(help)
    .sensoryFeedback(.success, trigger: copyCount)
    .onChange(of: isRevealed) { _, revealed in
      if !revealed { didCopy = false }
    }
  }
}

#Preview {
  MessageCopyButton(text: "Hello, world!")
    .padding()
}

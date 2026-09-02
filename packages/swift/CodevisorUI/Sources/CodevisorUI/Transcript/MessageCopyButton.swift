import SwiftUI

/// A small icon button shown below a transcript message that copies the
/// message text to the clipboard, flashing a checkmark as confirmation.
public struct MessageCopyButton: View {
  let text: String
  var help: String = "Copy message"
  /// The reveal state of the row that owns this button. Leaving the row
  /// clears the transient checkmark immediately, so coming back always
  /// shows the copy icon instead of a stale check.
  var isRevealed: Bool = true
  @State private var didCopy = false

  public init(text: String, help: String = "Copy message", isRevealed: Bool = true) {
    self.text = text
    self.help = help
    self.isRevealed = isRevealed
  }

  public var body: some View {
    Button {
      PlatformPasteboard.copy(text)
      didCopy = true
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        didCopy = false
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
    .onChange(of: isRevealed) { _, revealed in
      if !revealed { didCopy = false }
    }
  }
}

#Preview {
  MessageCopyButton(text: "Hello, world!")
    .padding()
}

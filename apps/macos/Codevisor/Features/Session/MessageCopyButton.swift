import SwiftUI
import AppKit

/// A small icon button shown below a transcript message that copies the
/// message text to the clipboard, flashing a checkmark as confirmation.
struct MessageCopyButton: View {
    let text: String
    var help: String = "Copy message"
    /// The reveal state of the row that owns this button. Leaving the row
    /// clears the transient checkmark immediately, so coming back always
    /// shows the copy icon instead of a stale check.
    var isRevealed: Bool = true
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
        .tooltip(help)
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

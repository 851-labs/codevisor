import ACPKit
import CodevisorCore
import SwiftUI

/// A small icon button shown below a transcript message that copies the
/// message text to the clipboard, flashing a checkmark as confirmation.
public struct MessageCopyButton: View {
  let text: String
  let resource: ToolDetailResource?
  @Environment(\.transcriptController) private var controller
  @Environment(\.transcriptCopyResource) private var inheritedResource
  @State private var copyTask: Task<Void, Never>?
  @State private var isCopying = false
  @State private var copyError: String?
  var help: String = "Copy message"
  /// The reveal state of the row that owns this button. Leaving the row
  /// clears the transient checkmark immediately, so coming back always
  /// shows the copy icon instead of a stale check.
  var isRevealed: Bool = true
  @State private var didCopy = false
  /// Bumped on every copy so the haptic fires on each tap, including
  /// re-copies while the checkmark is still showing (`didCopy` would not
  /// change again in that window).
  @State private var copyCount = 0

  public init(text: String, help: String = "Copy message", isRevealed: Bool = true, resource: ToolDetailResource? = nil)
  {
    self.text = text
    self.resource = resource
    self.help = help
    self.isRevealed = isRevealed
  }

  public var body: some View {
    Button {
      if let resource = resource ?? inheritedResource {
        guard let controller else { copyError = "Reconnect to copy this message."; return }
        isCopying = true
        copyTask = Task {
          defer { isCopying = false }
          do {
            let fullText = try await controller.completeTranscriptText(resource: resource)
            try Task.checkCancellation()
            copy(fullText)
          } catch {
            if !isTaskCancellation(error) { copyError = serverErrorMessage(error) }
          }
        }
      } else {
        copy(text)
      }
    } label: {
      Group {
        if isCopying {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        }
      }
      .font(.caption)
      .frame(width: 20, height: 20)
      .contentShape(Rectangle())
    }
    .disabled(isCopying)
    .onDisappear { copyTask?.cancel() }
    .alert(
      "Couldn't copy message", isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })
    ) {
      Button("OK") { copyError = nil }
    } message: {
      Text(copyError ?? "")
    }
    .buttonStyle(HoverIconButtonStyle(shape: .roundedRectangle))
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(help)
    // HIG › Playing haptics: `.success` is the notification feedback for a
    // task that completed, which is what a copy is. It is a no-op on macOS.
    .sensoryFeedback(.success, trigger: copyCount)
    .onChange(of: isRevealed) { _, revealed in
      if !revealed { didCopy = false }
    }
  }
  private func copy(_ text: String) {
    PlatformPasteboard.copy(text)
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      didCopy = true; copyCount += 1
    }
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      withTransaction(transaction) { didCopy = false }
    }
  }

}

#Preview {
  MessageCopyButton(text: "Hello, world!")
    .padding()
}

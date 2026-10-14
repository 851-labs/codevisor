import SwiftUI

struct CodeHeaderCopyButton: View {
  let text: String
  @State private var didCopy = false
  @State private var resetTask: Task<Void, Never>?

  var body: some View {
    Button {
      PlatformPasteboard.copy(text)
      didCopy = true
      resetTask?.cancel()
      resetTask = Task {
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        didCopy = false
      }
    } label: {
      Label {
        Text(didCopy ? "Copied" : "Copy")
      } icon: {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
          .frame(width: 13, height: 13)
      }
      .font(.caption2)
      .labelStyle(.titleAndIcon)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .onDisappear { resetTask?.cancel() }
  }
}

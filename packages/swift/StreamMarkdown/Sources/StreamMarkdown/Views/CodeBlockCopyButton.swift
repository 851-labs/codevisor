import SwiftUI
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

struct CodeBlockCopyButton: View {
  let code: String
  @State private var didCopy = false
  @State private var copyResetTask: Task<Void, Never>?

  var body: some View {
    Button(action: copy) {
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
  }

  private func copy() {
    #if canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(code, forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string = code
    #endif
    didCopy = true
    copyResetTask?.cancel()
    copyResetTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      didCopy = false
    }
  }
}

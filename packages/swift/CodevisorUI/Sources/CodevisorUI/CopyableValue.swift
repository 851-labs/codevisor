import SwiftUI

public struct CopyableValue: View {
  let value: String

  public init(value: String) {
    self.value = value
  }

  public var body: some View {
    HStack(spacing: 6) {
      Text(value)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Button("Copy", systemImage: "doc.on.doc") { PlatformPasteboard.copy(value) }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Copy")
    }
  }
}

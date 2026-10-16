import SwiftUI

public struct MachineConnectionBadge: View {
  let connection: MachineConnectionPresentation
  let font: Font

  public init(_ connection: MachineConnectionPresentation, font: Font = .caption) {
    self.connection = connection
    self.font = font
  }

  public var body: some View {
    HStack(spacing: 5) {
      switch connection.indicator {
      case .busy:
        ProgressView()
          .controlSize(.mini)
      case .connected, .inactive:
        Circle()
          .fill(connection.indicator == .connected ? Color.green : Color.gray)
          .frame(width: 7, height: 7)
      }
      Text(connection.label())
        .font(font)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .help(connection.help ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(connection.label())
  }
}

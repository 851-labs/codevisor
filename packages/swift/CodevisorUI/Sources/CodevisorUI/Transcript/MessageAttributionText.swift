import SwiftUI
import TranscriptKit

public struct MessageAttributionText: View {
  let name: String

  public init?(_ attribution: UserMessageAttribution?) {
    guard let name = attribution?.displayName else { return nil }
    self.name = name
  }

  public var body: some View {
    Text("via \(name)")
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityLabel("Sent by \(name)")
  }
}

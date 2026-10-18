import SwiftUI

public struct TranscriptBotNoticeRow: View {
  let text: String

  public init(text: String) {
    self.text = text
  }

  public var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
  }
}

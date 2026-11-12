import CodevisorCore
import SwiftUI

struct TranscriptEventPopover: View {
  private static let width: CGFloat = 460
  private static let maxHeight: CGFloat = 420

  let marker: TranscriptEventMarker

  var body: some View {
    ScrollView {
      Text(text)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
    .frame(width: Self.width)
    .frame(maxHeight: Self.maxHeight)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var text: String {
    marker.events.map(\.body).joined(separator: "\n\n")
  }
}

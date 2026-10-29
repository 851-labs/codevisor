import SwiftUI

struct TranscriptCompactionMarker: View {
  var body: some View {
    Label("Context compacted", systemImage: "arrow.down.right.and.arrow.up.left")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

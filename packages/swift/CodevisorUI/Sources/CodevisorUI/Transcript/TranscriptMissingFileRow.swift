import SwiftUI
import TranscriptKit

struct TranscriptMissingFileRow: View {
  let file: PreviewFile

  var body: some View {
    TranscriptFileStatusRow(file: file) {
      Text("File Not Found")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

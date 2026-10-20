import SwiftUI
import TranscriptKit

struct TranscriptFileLoadingRow: View {
  let file: PreviewFile

  var body: some View {
    TranscriptFileStatusRow(file: file) {
      ProgressView()
        .controlSize(.mini)
    }
  }
}

import SwiftUI
import TranscriptKit

struct TranscriptFileTruncationFooter: View {
  let file: PreviewFile

  var body: some View {
    TranscriptFileOpenButton(file: file) {
      Text("Open to see more")
        .font(.caption)
        .foregroundStyle(.tint)
    }
  }
}

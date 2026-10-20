import SwiftUI
import TranscriptKit

struct TranscriptFileHeader: View {
  let file: PreviewFile

  var body: some View {
    TranscriptFileOpenButton(file: file) {
      HStack(spacing: 6) {
        FileIcon(path: file.name, size: 14)
        Text(file.name)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .accessibilityLabel("Open \(file.name)")
  }
}

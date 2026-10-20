import SwiftUI
import TranscriptKit

struct TranscriptCaptionedThumbnail<Thumbnail: View>: View {
  let file: PreviewFile
  let label: String
  let showsCaption: Bool
  let thumbnail: Thumbnail

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      thumbnail
        .accessibilityLabel(label)
      if showsCaption, file.kind != .image {
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

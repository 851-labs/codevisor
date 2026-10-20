import StreamMarkdown
import SwiftUI
import TranscriptKit

struct TranscriptFileCodeBlock: View {
  let file: PreviewFile
  let excerpt: FileTextExcerpt

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      CodeBlockView(
        id: "file-preview:\(file.id)",
        language: file.highlightLanguage,
        code: excerpt.content,
        isComplete: true,
        maxHeight: TranscriptFilePreviewMetrics.maximumContentHeight
      ) {
        TranscriptFileHeader(file: file)
      } accessory: {
        TranscriptFileOpenAccessory(file: file)
      }
      if excerpt.isTruncated {
        TranscriptFileTruncationFooter(file: file)
      }
    }
  }
}

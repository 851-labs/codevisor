import StreamMarkdown
import SwiftUI
import TranscriptKit

struct TranscriptDiffPreview: View {
  @Environment(\.markdownTheme) private var theme
  @Environment(\.markdownBlockChrome) private var chrome
  let file: PreviewFile
  let diff: UnifiedDiff
  let isTruncated: Bool

  var body: some View {
    if chrome.drawsFrame {
      framed
    } else {
      TranscriptBotFileBubble(file: file, showsName: false, note: isTruncated ? "Showing the start of the file" : nil) {
        CodeBlockHeightLimit(maxHeight: TranscriptFilePreviewMetrics.maximumContentHeight) {
          sections
        }
      }
    }
  }

  private var framed: some View {
    VStack(alignment: .leading, spacing: 4) {
      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        CodeBlockHeightLimit(maxHeight: TranscriptFilePreviewMetrics.maximumContentHeight) {
          sections
        }
      }
      .background(theme.codeBackground)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      if isTruncated {
        TranscriptFileTruncationFooter(file: file)
      }
    }
  }

  private var header: some View {
    HStack {
      TranscriptFileHeader(file: file)
      Spacer()
      TranscriptFileOpenAccessory(file: file)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private var sections: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(diff.files) { file in
        TranscriptDiffFileSection(file: file)
      }
    }
  }
}

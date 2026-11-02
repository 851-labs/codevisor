import StreamMarkdown
import SwiftUI
import TranscriptKit

struct TranscriptFileStatusRow<Status: View>: View {
  @Environment(\.markdownTheme) private var theme
  @Environment(\.markdownBlockChrome) private var chrome
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let file: PreviewFile
  @ViewBuilder let status: Status

  var body: some View {
    HStack(spacing: 6) {
      FileIcon(path: file.name, size: 14)
      Text(displayPath)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      status
    }
    .padding(.horizontal, chrome.drawsFrame ? 10 : 12)
    .padding(.vertical, 8)
    .background(chrome.drawsFrame ? theme.codeBackground : Color.bubbleBackground, in: shape)
  }

  private var shape: RoundedRectangle {
    chrome.drawsFrame ? RoundedRectangle(cornerRadius: 8) : UserBubbleBackground.shape(for: dynamicTypeSize)
  }

  private var displayPath: String {
    guard case let .serverPath(path) = file.source else { return file.name }
    return path
  }
}

import StreamMarkdown
import SwiftUI
import TranscriptKit

struct TranscriptFileStatusRow<Status: View>: View {
  @Environment(\.markdownTheme) private var theme
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
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
  }

  private var displayPath: String {
    guard case let .serverPath(path) = file.source else { return file.name }
    return path
  }
}

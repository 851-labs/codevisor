import SwiftUI
import TranscriptKit

struct TranscriptDiffFileHeader: View {
  let file: UnifiedDiff.File

  var body: some View {
    HStack(spacing: 8) {
      FileIcon(path: file.path, size: 14)
      Text(file.path)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      DiffCounter(totals: file.totals)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }
}

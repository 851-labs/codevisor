import SwiftUI

struct TranscriptDiffHunkHeader: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.monospaced())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: ReviewMetrics.foldRowHeight, alignment: .leading)
      .background(Color.accentColor.opacity(0.08))
  }
}

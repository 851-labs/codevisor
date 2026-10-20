import SwiftUI
import TranscriptKit

struct TranscriptDiffHunkRows: View {
  let rows: [LineDiff.Row]
  let highlights: [Int: AttributedString]
  let revision: String
  let lineNumberDigits: Int
  let scrollSync: DiffScrollSync

  var body: some View {
    #if canImport(AppKit)
      NativeDiffView(
        rows: rows, highlights: highlights, revision: revision,
        maximumHeight: nil, lineNumberDigits: lineNumberDigits, scrollSync: scrollSync
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativeDiffView(
        rows: rows, highlights: highlights, revision: revision,
        maximumHeight: nil, lineNumberDigits: lineNumberDigits, scrollSync: scrollSync
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    #endif
  }
}

#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI

  struct MarkdownPortableTableView: View {
    let headers: [MarkdownText]
    let alignments: [ColumnAlignment]
    let rows: [[MarkdownText]]
    @Environment(\.resolvedMarkdownTableBleed) private var bleed

    var body: some View {
      if !headers.isEmpty || rows.contains(where: { !$0.isEmpty }) {
        VirtualizedMarkdownTableView(headers: headers, alignments: alignments, rows: rows)
          .padding(.horizontal, -bleed)
      }
    }
  }
#endif

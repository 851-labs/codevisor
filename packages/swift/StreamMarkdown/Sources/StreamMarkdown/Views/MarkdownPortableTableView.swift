#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI

  /// A single native horizontal viewport with cells mounted on demand.
  /// Content margins preserve text-column alignment while wide tables can
  /// scroll through the transcript's side gutters.
  struct MarkdownPortableTableView: View {
    let headers: [MarkdownText]
    let alignments: [ColumnAlignment]
    let rows: [[MarkdownText]]
    @Environment(\.markdownTableBleed) private var bleed

    var body: some View {
      if !headers.isEmpty || rows.contains(where: { !$0.isEmpty }) {
        VirtualizedMarkdownTableView(headers: headers, alignments: alignments, rows: rows)
          .padding(.horizontal, -bleed)
      }
    }
  }
#endif

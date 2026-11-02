import StreamMarkdown
import SwiftUI
import TranscriptKit

struct TranscriptBotTablePreview<Fallback: View>: View {
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.markdownTheme) private var theme
  @State private var loaded: DelimitedTablePreviews.Result?
  @State private var layoutWaitExpired = false
  private let file: PreviewFile
  private let delimiter: Character
  private let fallback: Fallback

  init(file: PreviewFile, delimiter: Character, @ViewBuilder fallback: () -> Fallback) {
    self.file = file
    self.delimiter = delimiter
    self.fallback = fallback()
  }

  var body: some View {
    content
      .task(id: file.id) { await load() }
      .task(id: file.id) { await expireLayoutWait() }
      .preference(key: ContentLayoutReadinessPreferenceKey.self, value: holdsLayout ? 1 : 0)
  }

  @ViewBuilder private var content: some View {
    switch result {
    case let .table(table): bubble(table)
    case .unreadable: fallback
    case nil: TranscriptFileLoadingRow(file: file)
    }
  }

  private func bubble(_ table: DelimitedTablePreview) -> some View {
    let blocks = [table.block]
    return TranscriptBotFileBubble(
      file: file, showsName: false, note: table.hiddenRowsNote,
      naturalWidth: MarkdownTableNaturalWidth.widest(in: blocks, theme: theme)
    ) {
      MarkdownBlockGroupsView(blocks: blocks, documentSource: "", streamID: "table-preview:\(file.id)")
        .environment(\.markdownTableBleedLimit, 0)
    }
  }

  private var result: DelimitedTablePreviews.Result? {
    guard attachmentImages != nil else { return .unreadable }
    return loaded ?? DelimitedTablePreviews.shared.cached(file)
  }

  private var holdsLayout: Bool { result == nil && !layoutWaitExpired }

  private func load() async {
    guard let attachmentImages, result == nil else { return }
    let result = await DelimitedTablePreviews.shared.load(file, delimiter: delimiter, from: attachmentImages)
    guard !Task.isCancelled else { return }
    loaded = result
  }

  private func expireLayoutWait() async {
    try? await Task.sleep(for: .milliseconds(600))
    guard !Task.isCancelled else { return }
    layoutWaitExpired = true
  }
}

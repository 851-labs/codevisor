import Foundation
import StreamMarkdown
import TranscriptKit

extension TranscriptPresentationRow {
  /// The Markdown find in chat searches in this row: final response text,
  /// including a proposed plan. Worked sections (tool calls, interim
  /// narration) and user prompts are left out.
  public var findableBlocks: [MarkdownBlock]? {
    guard case let .markdownChunk(chunk) = content, chunk.container != .assistantWorked else {
      return nil
    }
    return chunk.blocks
  }
}

/// Counts find-in-chat matches for a whole transcript away from the main
/// actor.
///
/// Rendering every row's plain text and scanning it is far too slow for the
/// main thread in a long chat, so it happens here, split across cores, and
/// stays cached per row: a new query rescans cached text, and a streaming
/// update recounts only the rows whose content changed. Callers cancel the
/// task awaiting a stale query; cancellation is checked between rows.
actor TranscriptFindIndex {
  /// One searchable row's count, with its position in the rows searched.
  struct RowCount: Sendable {
    let rowIndex: Int
    let count: TranscriptFindRowCount
  }

  private struct Entry {
    let blocks: [MarkdownBlock]
    let texts: [String]
    let query: String
    let count: Int
  }

  private struct Work: Sendable {
    let position: Int
    let key: String
    let blocks: [MarkdownBlock]
    let texts: [String]?
  }

  private struct Counted: Sendable {
    let position: Int
    let key: String
    let blocks: [MarkdownBlock]
    let texts: [String]
    let count: Int
  }

  private var entries: [String: Entry] = [:]
  private var themeFingerprint: Int?

  /// Match counts for every searchable row in `rows`, in document order.
  /// An empty query only builds and caches the rows' text.
  func counts(
    of query: String,
    in rows: [TranscriptPresentationRow],
    theme: MarkdownTheme
  ) async throws -> [RowCount] {
    let fingerprint = theme.renderFingerprint
    if themeFingerprint != fingerprint {
      themeFingerprint = fingerprint
      entries = [:]
    }

    var result: [RowCount] = []
    var work: [Work] = []
    for (rowIndex, row) in rows.enumerated() {
      guard let blocks = row.findableBlocks else { continue }
      let key = row.layoutKey
      let position = result.count
      // Unchanged rows share their projected block storage, so this
      // comparison is an identity check for everything but a streaming row.
      if let entry = entries[key], entry.blocks == blocks {
        if entry.query == query {
          result.append(RowCount(rowIndex: rowIndex, count: .init(rowKey: key, count: entry.count)))
          continue
        }
        work.append(Work(position: position, key: key, blocks: blocks, texts: entry.texts))
      } else {
        work.append(Work(position: position, key: key, blocks: blocks, texts: nil))
      }
      result.append(RowCount(rowIndex: rowIndex, count: .init(rowKey: key, count: 0)))
    }

    let counted = try await Self.count(work, query: query, theme: theme)
    // A concurrent call may have switched themes while this one was counting;
    // its results still answer this call but must not seed the new cache.
    let cacheable = themeFingerprint == fingerprint
    for item in counted {
      result[item.position] = RowCount(
        rowIndex: result[item.position].rowIndex,
        count: .init(rowKey: item.key, count: item.count)
      )
      if cacheable {
        entries[item.key] = Entry(blocks: item.blocks, texts: item.texts, query: query, count: item.count)
      }
    }
    if entries.count > result.count {
      let live = Set(result.map(\.count.rowKey))
      entries = entries.filter { live.contains($0.key) }
    }
    return result
  }

  func reset() {
    entries = [:]
  }

  /// Renders missing text and counts matches for `work`, split into one
  /// chunk per core.
  private static func count(
    _ work: [Work],
    query: String,
    theme: MarkdownTheme
  ) async throws -> [Counted] {
    guard !work.isEmpty else { return [] }
    let chunkCount = min(work.count, max(1, ProcessInfo.processInfo.activeProcessorCount))
    let chunkSize = (work.count + chunkCount - 1) / chunkCount
    return try await withThrowingTaskGroup(of: [Counted].self) { group in
      for start in stride(from: 0, to: work.count, by: chunkSize) {
        let chunk = work[start..<min(work.count, start + chunkSize)]
        group.addTask {
          try chunk.map { item in
            try Task.checkCancellation()
            let texts = item.texts ?? TranscriptFindText.surfaceTexts(blocks: item.blocks, theme: theme)
            let count = texts.reduce(0) { $0 + TranscriptFindText.count(of: query, in: $1) }
            return Counted(position: item.position, key: item.key, blocks: item.blocks, texts: texts, count: count)
          }
        }
      }
      var counted: [Counted] = []
      counted.reserveCapacity(work.count)
      for try await chunk in group { counted += chunk }
      return counted
    }
  }
}

import CodevisorClient

/// Three adjacent pages preserve scroll anchors while bounding resident detail.
struct TranscriptDetailWindow {
  private(set) var pages: [ServerTranscriptItemDetails] = []

  mutating func install(_ page: ServerTranscriptItemDetails, previous: Bool) -> ServerTranscriptItemDetails {
    if previous {
      pages.insert(page, at: 0)
      pages = Array(pages.prefix(3))
    } else {
      pages.append(page)
      pages = Array(pages.suffix(3))
    }
    var entries: [String: ServerTranscriptEntry] = [:]
    for retained in pages {
      for entry in retained.entries {
        if let existing = entries[entry.key], existing.revision > entry.revision { continue }
        entries[entry.key] = entry
      }
    }
    return ServerTranscriptItemDetails(
      itemId: page.itemId, revision: pages.map(\.revision).max() ?? page.revision,
      eventCursor: pages.map(\.eventCursor).min() ?? page.eventCursor,
      entries: entries.values.sorted { ($0.position, $0.key) < ($1.position, $1.key) },
      nextAfter: pages.last?.nextAfter, previousBefore: pages.first?.previousBefore)
  }
}

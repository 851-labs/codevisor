struct TranscriptItemBoundary {
  let sequence: Int
  let isPageStart: Bool

  static func cut(_ newestFirst: [TranscriptItemBoundary], keeping limit: Int) -> Int? {
    guard newestFirst.count > limit else { return nil }

    let pageStarts = newestFirst.enumerated().filter { $0.element.isPageStart }
    let withinLimit = pageStarts.last { $0.offset < limit }
    return (withinLimit ?? pageStarts.first)?.element.sequence
  }
}

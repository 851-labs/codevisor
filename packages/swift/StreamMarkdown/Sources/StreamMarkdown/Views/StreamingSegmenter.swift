import Combine
import Foundation

/// Computes render segments from a complete MD4C parse of each presented text
/// snapshot. Full-document parsing is intentional: CommonMark reference links
/// and container structure can change the interpretation of earlier text, so
/// independently parsing a supposedly settled tail is not semantics-preserving.
@MainActor
final class StreamingSegmenter {
  private let parser = MarkdownParser()
  private var lastText: String?
  private var lastIsComplete = true
  private var lastSegments: [MarkdownSegment] = []

  func segments(for text: String, isComplete: Bool) -> [MarkdownSegment] {
    if text == lastText, isComplete == lastIsComplete { return lastSegments }

    var segments =
      isComplete
      ? MarkdownSegmentCache.shared.segments(for: text)
      : MarkdownSegment.segments(from: parser.parse(text))

    // Reuse the value storage of the equal prefix. MD4C parses the whole
    // snapshot, but SwiftUI only needs to invalidate the first semantically
    // changed segment and what follows it.
    let sharedCount = min(segments.count, lastSegments.count)
    var index = 0
    while index < sharedCount, segments[index] == lastSegments[index] {
      segments[index] = lastSegments[index]
      index += 1
    }

    lastText = text
    lastIsComplete = isComplete
    lastSegments = segments
    return segments
  }

  nonisolated static func parseSnapshot(
    text: String,
    isComplete: Bool
  ) -> [MarkdownSegment] {
    let blocks = MarkdownParser().parse(text)
    return MarkdownSegment.segments(from: blocks)
  }
}

/// Observable asynchronous parser owned by one `StreamingMarkdownView`
/// identity. Initial content is parsed synchronously to avoid a blank mount;
/// later streamed snapshots never run MD4C or build the Swift IR on MainActor.
@MainActor
final class StreamingMarkdownParseCoordinator: ObservableObject {
  typealias SnapshotParser = @Sendable (String, Bool) -> [MarkdownSegment]

  struct Presentation: Sendable {
    let text: String
    let isComplete: Bool
    let renderSegments: [MarkdownRenderSegment]

    var segments: [MarkdownSegment] { renderSegments.map(\.segment) }
  }

  @Published private(set) var presentation: Presentation
  private var requestedText: String
  private var requestedIsComplete: Bool
  private var generation: UInt64 = 0
  private var nextSegmentID: UInt64
  private let snapshotParser: SnapshotParser

  init(
    text: String,
    isComplete: Bool,
    snapshotParser: @escaping SnapshotParser = {
      StreamingSegmenter.parseSnapshot(text: $0, isComplete: $1)
    }
  ) {
    requestedText = text
    requestedIsComplete = isComplete
    self.snapshotParser = snapshotParser
    let segments =
      isComplete
      ? MarkdownSegmentCache.shared.segments(for: text)
      : snapshotParser(text, false)
    let renderSegments = MarkdownRenderSegment.initial(segments)
    nextSegmentID = UInt64(renderSegments.count)
    presentation = Presentation(
      text: text,
      isComplete: isComplete,
      renderSegments: renderSegments
    )
  }

  func update(text: String, isComplete: Bool) async {
    guard text != requestedText || isComplete != requestedIsComplete else { return }
    requestedText = text
    requestedIsComplete = isComplete
    generation &+= 1
    let requestGeneration = generation

    if isComplete, let cached = MarkdownSegmentCache.shared.cachedSegments(for: text) {
      publish(cached, text: text, isComplete: true, generation: requestGeneration)
      return
    }

    let snapshotParser = snapshotParser
    let parsed = await Task.detached(priority: .userInitiated) {
      snapshotParser(text, isComplete)
    }.value
    guard !Task.isCancelled else { return }
    publish(parsed, text: text, isComplete: isComplete, generation: requestGeneration)
  }

  private func publish(
    _ parsed: [MarkdownSegment],
    text: String,
    isComplete: Bool,
    generation: UInt64
  ) {
    guard generation == self.generation,
      text == requestedText,
      isComplete == requestedIsComplete
    else { return }

    let previous = presentation.renderSegments
    let reconciled = reconcile(parsed, with: previous)
    if isComplete { MarkdownSegmentCache.shared.store(parsed, for: text) }
    presentation = Presentation(
      text: text,
      isComplete: isComplete,
      renderSegments: reconciled
    )
  }

  /// Preserves the equal prefix and suffix, plus the first changing tail
  /// block. That tail is the steady-state append target while streaming.
  private func reconcile(
    _ parsed: [MarkdownSegment],
    with previous: [MarkdownRenderSegment]
  ) -> [MarkdownRenderSegment] {
    let sharedCount = min(parsed.count, previous.count)
    var prefixCount = 0
    while prefixCount < sharedCount,
      parsed[prefixCount] == previous[prefixCount].segment
    {
      prefixCount += 1
    }

    var suffixCount = 0
    while suffixCount < sharedCount - prefixCount,
      parsed[parsed.count - 1 - suffixCount]
        == previous[previous.count - 1 - suffixCount].segment
    {
      suffixCount += 1
    }

    var result: [MarkdownRenderSegment] = []
    result.reserveCapacity(parsed.count)
    result.append(contentsOf: previous.prefix(prefixCount))

    let changedEnd = parsed.count - suffixCount
    for index in prefixCount..<changedEnd {
      let id: UInt64
      if index == prefixCount, index < previous.count - suffixCount {
        id = previous[index].id
      } else {
        id = nextSegmentID
        nextSegmentID &+= 1
      }
      result.append(MarkdownRenderSegment(id: id, segment: parsed[index]))
    }

    if suffixCount > 0 {
      result.append(contentsOf: previous.suffix(suffixCount))
    }
    return result
  }
}

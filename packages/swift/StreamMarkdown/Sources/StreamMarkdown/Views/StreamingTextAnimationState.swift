import Foundation
import QuartzCore

struct StreamingTextAnimationContext {
  let timeline: StreamingTextAnimationTimeline
  let sourceID: String
  let pacingSourceID: String
  let documentSource: String
  let isStreaming: Bool
  let animatesInitialContent: Bool
  let reduceMotion: Bool
  let playbackRevision: Int

  init(
    timeline: StreamingTextAnimationTimeline,
    sourceID: String,
    pacingSourceID: String? = nil,
    documentSource: String,
    isStreaming: Bool,
    animatesInitialContent: Bool,
    reduceMotion: Bool,
    playbackRevision: Int = 0
  ) {
    self.timeline = timeline
    self.sourceID = sourceID
    self.pacingSourceID = pacingSourceID ?? sourceID
    self.documentSource = documentSource
    self.isStreaming = isStreaming
    self.animatesInitialContent = animatesInitialContent
    self.reduceMotion = reduceMotion
    self.playbackRevision = playbackRevision
  }
}

enum StreamingTextRevealStyle: Equatable {
  case faded
  case atomic
}

final class StreamingTextFadeMetadata: NSObject, NSCopying {
  var startTime: TimeInterval
  var characterCount: Int
  let revealStyle: StreamingTextRevealStyle
  var minimumStartTime: TimeInterval?

  init(
    startTime: TimeInterval,
    characterCount: Int = 1,
    revealStyle: StreamingTextRevealStyle = .faded,
    minimumStartTime: TimeInterval? = nil
  ) {
    self.startTime = startTime
    self.characterCount = max(1, characterCount)
    self.revealStyle = revealStyle
    self.minimumStartTime = minimumStartTime
  }

  func copy(with _: NSZone? = nil) -> Any {
    self
  }

  func opacity(at time: TimeInterval) -> CGFloat {
    if revealStyle == .atomic {
      return time < startTime ? 0 : 1
    }
    let linearProgress = (time - startTime) / StreamingTextAnimationSpec.fadeDuration
    guard linearProgress > 0 else { return 0 }
    guard linearProgress < 1 else { return 1 }
    return CGFloat(StreamingTextFadeCurve.value(at: linearProgress))
  }

  var animationEndTime: TimeInterval {
    switch revealStyle {
    case .faded:
      startTime + StreamingTextAnimationSpec.fadeDuration
    case .atomic:
      startTime
    }
  }
}

extension NSAttributedString.Key {
  static let streamMarkdownFade = NSAttributedString.Key(
    "com.851labs.codevisor.streamMarkdownFade"
  )
}

struct PreparedStreamingText {
  let text: NSAttributedString
  let latestAnimationEnd: TimeInterval?
  let activeAnimationRanges: [NSRange]
}

@MainActor
final class StreamingTextAnimationState {
  private struct Word {
    let text: String
    let fade: StreamingTextFadeMetadata

    var revealStyle: StreamingTextRevealStyle { fade.revealStyle }
  }

  private var sourceID: String?
  private var documentSource = ""
  private var words: [Word] = []
  private weak var timeline: StreamingTextAnimationTimeline?

  func prepare(
    _ base: NSAttributedString,
    context: StreamingTextAnimationContext?,
    now: TimeInterval = CACurrentMediaTime()
  ) -> PreparedStreamingText {
    guard let context, context.isStreaming else {
      reset(at: now)
      return PreparedStreamingText(
        text: base,
        latestAnimationEnd: nil,
        activeAnimationRanges: []
      )
    }

    let presentationNow = context.timeline.presentationTime(at: now)

    if sourceID != context.sourceID {
      reset(at: presentationNow)
      sourceID = context.sourceID
    }
    timeline = context.timeline

    let ranges = StreamingWordSegmenter.segments(in: base.string)
    let sourceIsAppendOnly = context.documentSource.utf8.starts(with: documentSource.utf8)
    let oldWords = words
    var nextWords: [Word] = []
    nextWords.reserveCapacity(ranges.count)

    if !context.animatesInitialContent {
      context.timeline.discard(oldWords.map(\.fade), at: presentationNow)
      context.timeline.baselineSource(
        context.documentSource,
        sourceID: context.pacingSourceID
      )
      let settledStart = presentationNow - StreamingTextAnimationSpec.fadeDuration
      for range in ranges {
        nextWords.append(
          Word(
            text: range.text,
            fade: StreamingTextFadeMetadata(
              startTime: settledStart,
              revealStyle: range.revealStyle
            )
          ))
      }
      documentSource = context.documentSource
      words = nextWords
      return PreparedStreamingText(
        text: base,
        latestAnimationEnd: nil,
        activeAnimationRanges: []
      )
    }

    if context.reduceMotion {
      context.timeline.discard(oldWords.map(\.fade), at: presentationNow)
      context.timeline.baselineSource(
        context.documentSource,
        sourceID: context.pacingSourceID
      )
      let settledStart = presentationNow - StreamingTextAnimationSpec.fadeDuration
      for range in ranges {
        nextWords.append(
          Word(
            text: range.text,
            fade: StreamingTextFadeMetadata(
              startTime: settledStart,
              revealStyle: range.revealStyle
            )
          ))
      }
      documentSource = context.documentSource
      words = nextWords
      return PreparedStreamingText(
        text: base,
        latestAnimationEnd: nil,
        activeAnimationRanges: []
      )
    }

    let candidateReuseCount = min(oldWords.count, ranges.count)
    var reusedCount = 0
    while reusedCount < candidateReuseCount {
      let oldWord = oldWords[reusedCount]
      let range = ranges[reusedCount]
      guard oldWord.revealStyle == range.revealStyle else { break }
      guard sourceIsAppendOnly || oldWord.text == range.text else { break }
      reusedCount += 1
    }
    for index in 0..<reusedCount {
      oldWords[index].fade.characterCount = max(1, ranges[index].range.length)
    }
    context.timeline.observeSource(
      context.documentSource,
      sourceID: context.pacingSourceID,
      at: presentationNow
    )

    if reusedCount < oldWords.count {
      context.timeline.discard(
        Array(oldWords.dropFirst(reusedCount)).map(\.fade),
        at: presentationNow
      )
    }
    let scheduled = context.timeline.scheduleSegments(
      characterCounts: ranges.dropFirst(reusedCount).map(\.range.length),
      revealStyles: ranges.dropFirst(reusedCount).map(\.revealStyle),
      at: presentationNow
    )
    for index in 0..<reusedCount
    where oldWords[index].revealStyle == .atomic
      && oldWords[index].text != ranges[index].text
    {
      context.timeline.restabilizeAtomicSegment(
        oldWords[index].fade,
        at: presentationNow
      )
    }
    var scheduledIndex = 0
    for (index, range) in ranges.enumerated() {
      let word: Word
      if index < reusedCount {
        word = Word(text: range.text, fade: oldWords[index].fade)
      } else {
        word = Word(
          text: range.text,
          fade: scheduled[scheduledIndex]
        )
        scheduledIndex += 1
      }
      nextWords.append(word)
    }

    let output = NSMutableAttributedString(attributedString: base)
    var latestEnd: TimeInterval?
    var activeAnimationRanges: [NSRange] = []
    for (range, word) in zip(ranges, nextWords) {
      let end = word.fade.animationEndTime
      guard end > presentationNow else { continue }
      output.addAttribute(
        .streamMarkdownFade,
        value: word.fade,
        range: range.range
      )
      activeAnimationRanges.append(range.range)
      latestEnd = max(latestEnd ?? end, end)
    }

    documentSource = context.documentSource
    words = nextWords
    return PreparedStreamingText(
      text: output,
      latestAnimationEnd: latestEnd,
      activeAnimationRanges: activeAnimationRanges
    )
  }

  func reset(at now: TimeInterval = CACurrentMediaTime()) {
    timeline?.discard(words.map(\.fade), at: now)
    sourceID = nil
    documentSource = ""
    words = []
    timeline = nil
  }
}

import SwiftUI

/// One SwiftUI identity's claim on a semantic text stream. A baseline lasts
/// for exactly the first rendered pass, long enough for every native Markdown
/// surface to seed its word reconciler, and then switches to normal live mode.
@MainActor
final class StreamingMarkdownAnimationMount {
  struct Resolution {
    let animatesInitialContent: Bool
    let activationToken: Int
    let needsActivation: Bool
  }

  private var hasResolved = false
  private var streamID: String?
  private var presentationID: ObjectIdentifier?
  private var settlementToken: Int?
  private var isBaselining = false
  private var activationToken = 0

  func resolve(
    streamID: String?,
    presentation: StreamingTextAnimationPresentation?
  ) -> Resolution {
    let nextPresentationID = presentation.map(ObjectIdentifier.init)
    let nextSettlementToken = streamID.flatMap { presentation?.settlementToken(for: $0) }
    if !hasResolved || self.streamID != streamID || presentationID != nextPresentationID {
      hasResolved = true
      self.streamID = streamID
      presentationID = nextPresentationID
      settlementToken = nextSettlementToken
      if let streamID, let presentation {
        isBaselining =
          nextSettlementToken != nil
          || !presentation.claimInitialAnimation(for: streamID)
      } else {
        // Standalone callers retain the original behavior: an
        // incomplete view animates the text it is first given.
        isBaselining = false
      }
      if isBaselining { activationToken &+= 1 }
    } else if settlementToken != nextSettlementToken {
      settlementToken = nextSettlementToken
      isBaselining = nextSettlementToken != nil
      if isBaselining { activationToken &+= 1 }
    }
    return Resolution(
      animatesInitialContent: !isBaselining,
      activationToken: activationToken,
      needsActivation: isBaselining
    )
  }

  func activate(token: Int) -> Bool {
    guard isBaselining, token == activationToken else { return false }
    isBaselining = false
    return true
  }
}

/// Renders Markdown text as complete MD4C document snapshots so streamed
/// responses remain CommonMark-correct while they grow. Blocks render in
/// document order, including tool output and partially-arrived code fences.
///
/// Pass `isComplete: false` while the text is still streaming. Snapshot parsing
/// then runs off the main actor, stale results are discarded, and unchanged
/// prefix values are reused to preserve SwiftUI identity. When the flag flips
/// back to true, the final result is cached without changing block topology.
/// The default (`true`) is right for text that arrives whole.
public struct StreamingMarkdownView: View {
  private let text: String
  private let isComplete: Bool
  private let foregroundColor: Color?
  private let streamID: String?
  private let animationPresentation: StreamingTextAnimationPresentation?
  private let animationCoordinator: StreamingContentAnimationCoordinator?
  private let animationEnabled: Bool
  @Environment(\.markdownTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Per-view-identity parse state. Streaming updates parse off MainActor and
  /// stale generations are discarded before they can replace newer text.
  @StateObject private var parseCoordinator: StreamingMarkdownParseCoordinator
  /// Message-wide visual cadence. Individual native text surfaces retain
  /// their own word identities but draw start times from this one queue.
  @State private var animationTimeline = StreamingTextAnimationTimeline()
  @State private var hasActiveEntranceAnimation = false
  /// Separates a semantic stream's first live appearance from a native view
  /// remount. The companion revision is only an invalidation signal after a
  /// one-pass baseline; the mount object itself remains non-observable.
  @State private var animationMount = StreamingMarkdownAnimationMount()
  @State private var animationMountRevision = 0

  public init(
    _ text: String,
    isComplete: Bool = true,
    foregroundColor: Color? = nil,
    streamID: String? = nil,
    animationPresentation: StreamingTextAnimationPresentation? = nil,
    animationCoordinator: StreamingContentAnimationCoordinator? = nil,
    animationEnabled: Bool = true
  ) {
    self.text = text
    self.isComplete = isComplete
    self.foregroundColor = foregroundColor
    self.streamID = streamID
    self.animationPresentation = animationPresentation
    self.animationCoordinator = animationCoordinator
    self.animationEnabled = animationEnabled
    _parseCoordinator = StateObject(
      wrappedValue: StreamingMarkdownParseCoordinator(text: text, isComplete: isComplete)
    )
  }

  public var body: some View {
    let mount = animationMount.resolve(
      streamID: streamID,
      presentation: animationPresentation
    )
    let _ = animationMountRevision
    let resolvedAnimationTimeline = animationCoordinator?.timeline ?? animationTimeline
    let parsed = parseCoordinator.presentation
    let presentsAnimation = !parsed.isComplete && animationEnabled
    let pacingSourceID = streamID ?? "root"
    let playbackRevision = animationCoordinator?.playbackRevision ?? 0
    MarkdownSegmentListView(
      segments: parsed.renderSegments,
      foregroundColor: foregroundColor ?? theme.textForeground,
      animationTimeline: presentsAnimation ? resolvedAnimationTimeline : nil,
      animatesInitialContent: mount.animatesInitialContent,
      documentSource: parsed.text,
      pacingSourceID: pacingSourceID,
      // A reused SwiftUI/native surface must reset its word reconciler
      // when the semantic transcript entry changes.
      animationPath: streamID.map { "stream.\($0).root" } ?? "root",
      reduceMotion: reduceMotion,
      playbackRevision: playbackRevision
    )
    .preference(
      key: StreamingMarkdownEntranceAnimationPreferenceKey.self,
      value: animationCoordinator?.hasActiveEntranceAnimation
        ?? hasActiveEntranceAnimation
    )
    .onAppear {
      guard animationCoordinator == nil else { return }
      resolvedAnimationTimeline.observeActivity { active in
        hasActiveEntranceAnimation = active
      }
    }
    .onDisappear {
      if let animationCoordinator {
        animationCoordinator.setPendingEntrance(
          false,
          sourceID: streamID ?? "root"
        )
        return
      }
      resolvedAnimationTimeline.observeActivity(nil)
      hasActiveEntranceAnimation = false
    }
    .onPreferenceChange(StreamingMarkdownPendingEntrancePreferenceKey.self) { pending in
      animationCoordinator?.setPendingEntrance(
        pending,
        sourceID: streamID ?? "root"
      )
    }
    .onChange(of: isComplete, initial: true) { _, complete in
      if complete { resolvedAnimationTimeline.reset() }
    }
    .onChange(of: reduceMotion) { _, reduced in
      if reduced { resolvedAnimationTimeline.reset() }
    }
    .onChange(of: animationEnabled) { _, enabled in
      if !enabled { resolvedAnimationTimeline.reset() }
    }
    .task(id: mount.activationToken) {
      guard mount.needsActivation else { return }
      // The first native surfaces must consume the baseline before the
      // same semantic stream becomes eligible for later append fades.
      await Task.yield()
      if animationMount.activate(token: mount.activationToken) {
        animationMountRevision &+= 1
      }
    }
    .task(id: MarkdownParseRequest(text: text, isComplete: isComplete)) {
      await parseCoordinator.update(text: text, isComplete: isComplete)
    }
  }
}

private struct MarkdownParseRequest: Hashable {
  let text: String
  let isComplete: Bool
}

/// Aggregates the entrance-animation state of every streamed Markdown surface
/// beneath a transcript row. Multiple commentary blocks can animate at once,
/// so preference reduction is an OR rather than last-writer-wins.
public struct StreamingMarkdownEntranceAnimationPreferenceKey: PreferenceKey {
  public static let defaultValue = false

  public static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

private struct StreamingMarkdownPendingEntrancePreferenceKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

/// Renders Markdown blocks with the same one-block-per-segment topology used
/// by the streaming and settled document paths.
struct MarkdownSegmentsView: View {
  let blocks: [MarkdownBlock]
  let foregroundColor: Color
  var animationTimeline: StreamingTextAnimationTimeline?
  var animatesInitialContent = true
  var playbackRevision = 0
  var documentSource = ""
  var pacingSourceID = "nested"
  var animationPath = "nested"
  var reduceMotion = false

  var body: some View {
    MarkdownSegmentListView(
      segments: MarkdownRenderSegment.initial(MarkdownSegment.segments(from: blocks)),
      foregroundColor: foregroundColor,
      animationTimeline: animationTimeline,
      animatesInitialContent: animatesInitialContent,
      documentSource: documentSource,
      pacingSourceID: pacingSourceID,
      animationPath: animationPath,
      reduceMotion: reduceMotion,
      playbackRevision: playbackRevision
    )
  }
}

/// Renders pre-computed markdown segments in document order.
struct MarkdownSegmentListView: View {
  let segments: [MarkdownRenderSegment]
  let foregroundColor: Color
  let animationTimeline: StreamingTextAnimationTimeline?
  let animatesInitialContent: Bool
  let documentSource: String
  let pacingSourceID: String
  let animationPath: String
  let reduceMotion: Bool
  var playbackRevision = 0
  @Environment(\.markdownTheme) private var theme
  @State private var blockEntranceSequence = StreamingMarkdownBlockEntranceSequence()
  @State private var blockEntranceRevision = 0

  var body: some View {
    let resolution = blockEntranceSequence.resolve(
      segments: segments,
      animationPath: animationPath,
      animationEnabled: animationTimeline != nil,
      animatesInitialContent: animatesInitialContent,
      reduceMotion: reduceMotion
    )
    let _ = blockEntranceRevision
    VStack(alignment: .leading, spacing: theme.blockSpacing) {
      ForEach(Array(segments.enumerated()), id: \.element.id) { index, renderSegment in
        if index < resolution.visibleSegmentCount {
          MarkdownSegmentView(
            segment: renderSegment.segment,
            foregroundColor: foregroundColor,
            animationTimeline: animationTimeline,
            animationEnabled: animationTimeline != nil,
            animatesInitialContent: animatesInitialContent,
            documentSource: documentSource,
            pacingSourceID: pacingSourceID,
            animationPath: "\(animationPath).\(renderSegment.id)",
            reduceMotion: reduceMotion,
            playbackRevision: playbackRevision
          )
          .equatable()
          .transition(
            resolution.revealingSegmentIndex == index
              ? .opacity
              : .identity
          )
        }
      }
    }
    .preference(
      key: StreamingMarkdownEntranceAnimationPreferenceKey.self,
      value: resolution.hasActiveEntrance
    )
    .preference(
      key: StreamingMarkdownPendingEntrancePreferenceKey.self,
      value: resolution.hasActiveEntrance
    )
    .task(id: resolution.pendingBlockID) {
      guard let blockID = resolution.pendingBlockID,
        let animationTimeline
      else { return }

      do {
        // Native text surfaces schedule their words during the render
        // pass. Yield once so their exact deadline is on the shared
        // timeline before deciding that the prefix has finished.
        try await animationTimeline.waitUntilIdle()
        switch blockEntranceSequence.beginReveal(blockID: blockID) {
        case .started:
          animationTimeline.scheduleBlockEntrance()
          withAnimation(
            .timingCurve(
              StreamingTextAnimationSpec.fadeCurveX1,
              StreamingTextAnimationSpec.fadeCurveY1,
              StreamingTextAnimationSpec.fadeCurveX2,
              StreamingTextAnimationSpec.fadeCurveY2,
              duration: StreamingTextAnimationSpec.fadeDuration
            )
          ) {
            blockEntranceRevision &+= 1
          }
        case .resumed:
          break
        case .unavailable:
          return
        }

        // A quote may mount nested animated prose with its bar. Wait
        // for both the block fade and any such child text before
        // activating the following document segment.
        try await animationTimeline.waitUntilIdle()
        guard blockEntranceSequence.finishReveal(blockID: blockID) else { return }
        blockEntranceRevision &+= 1
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }
}

/// An unchanged streaming segment is an explicit SwiftUI equality boundary.
/// Growing the hosting surface still lays out the stack, but it cannot rebuild
/// or repaint the already-rendered prefix; only the changing tail crosses this
/// boundary. The parse coordinator reuses equal prefix values,
/// making the comparison O(1) in the steady state.
private struct MarkdownSegmentView: View, Equatable {
  let segment: MarkdownSegment
  let foregroundColor: Color
  let animationTimeline: StreamingTextAnimationTimeline?
  let animationEnabled: Bool
  let animatesInitialContent: Bool
  let documentSource: String
  let pacingSourceID: String
  let animationPath: String
  let reduceMotion: Bool
  let playbackRevision: Int

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.segment == rhs.segment
      && lhs.foregroundColor == rhs.foregroundColor
      && lhs.animationEnabled == rhs.animationEnabled
      && lhs.animatesInitialContent == rhs.animatesInitialContent
      && lhs.pacingSourceID == rhs.pacingSourceID
      && lhs.animationPath == rhs.animationPath
      && lhs.reduceMotion == rhs.reduceMotion
      && lhs.playbackRevision == rhs.playbackRevision
  }

  var body: some View {
    switch segment {
    case let .textRun(runBlocks):
      #if canImport(AppKit) || canImport(UIKit)
        MarkdownTextRunView(
          blocks: runBlocks,
          foregroundColor: foregroundColor,
          animationContext: animationTimeline.map {
            StreamingTextAnimationContext(
              timeline: $0,
              sourceID: animationPath,
              pacingSourceID: pacingSourceID,
              documentSource: documentSource,
              isStreaming: true,
              animatesInitialContent: animatesInitialContent,
              reduceMotion: reduceMotion,
              playbackRevision: playbackRevision
            )
          }
        )
      #else
        MarkdownPortableTextRunView(blocks: runBlocks, foregroundColor: foregroundColor)
      #endif
    case let .block(block):
      MarkdownBlockView(
        block: block,
        foregroundColor: foregroundColor,
        animationTimeline: animationTimeline,
        animatesInitialContent: animatesInitialContent,
        playbackRevision: playbackRevision,
        documentSource: documentSource,
        pacingSourceID: pacingSourceID,
        animationPath: animationPath,
        reduceMotion: reduceMotion
      )
    }
  }
}

#Preview("Rich document") {
  ScrollView {
    StreamingMarkdownView(
      """
      # Heading One

      A paragraph with **bold**, *italic*, and `inline code`.

      - First bullet
      - Second bullet

      1. Step one
      2. Step two

      > A thoughtful quote.

      | Name | Role |
      | :--- | ---: |
      | Ann  | Lead |

      ```swift
      let greeting = "Hello"
      print(greeting)
      ```

      ---
      Done.
      """
    )
    .padding()
  }
  .frame(width: 460, height: 640)
}

#Preview("Streaming (incomplete fence)") {
  StreamingMarkdownView(
    """
    Here is some code being written:

    ```swift
    func work() {
        let value = 4
    """
  )
  .padding()
  .frame(width: 420)
}

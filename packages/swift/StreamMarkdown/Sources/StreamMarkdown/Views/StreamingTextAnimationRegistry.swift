import SwiftUI

/// Animation ownership shared by every virtual Markdown row on one retained
/// transcript surface. Row hosts are free to remount or change renderer while
/// semantic stream claims and response-wide pacing remain stable.
@MainActor
public final class StreamingTextAnimationRegistry {
  public let presentation = StreamingTextAnimationPresentation()
  private var coordinators: [String: StreamingContentAnimationCoordinator] = [:]
  private var knownProjectedStreamIDs: Set<String> = []
  private var settledRestorationIDs: Set<String> = []
  private var hasObservedProjection = false
  private var awaitsPresentationBaseline = false
  private var lastProjectionRevision: UInt64?
  private var baselineProjectionRevision: UInt64?
  private var isPlaybackSuspended = false

  public init() {}

  public func coordinator(for semanticStreamID: String) -> StreamingContentAnimationCoordinator {
    if let coordinator = coordinators[semanticStreamID] { return coordinator }
    let coordinator = StreamingContentAnimationCoordinator()
    if isPlaybackSuspended { coordinator.suspendPlayback() }
    coordinators[semanticStreamID] = coordinator
    return coordinator
  }

  public func retireCoordinator(for semanticStreamID: String) {
    coordinators.removeValue(forKey: semanticStreamID)?.reset()
  }

  /// Marks the next authoritative projection as navigation state. Provider
  /// events can continue while a transcript is detached, so the registry
  /// must baseline the complete snapshot on reattachment before it resumes
  /// treating later projection deltas as live arrivals.
  public func prepareForPresentation() {
    awaitsPresentationBaseline = true
    baselineProjectionRevision = lastProjectionRevision
  }

  /// Observes the complete active Markdown row set before a virtualizer can
  /// mount any of it. The first snapshot is navigation state and therefore
  /// starts opaque. Later rows animate only at the followed live edge;
  /// offscreen arrivals are already presented when scrolling reaches them.
  /// A restoration identity belongs to the published snapshot and remains
  /// unchanged on later live appends. Its first projection settles both new
  /// historical rows and restored text in already-mounted rows.
  public func observeProjectedStreams<S: Sequence>(
    _ streamIDs: S,
    animatesNewStreams: Bool,
    initialProjectionIsPending: Bool = false,
    restorationID: String? = nil,
    projectionRevision: UInt64? = nil
  ) where S.Element == String {
    defer { lastProjectionRevision = projectionRevision }
    let current = Set(streamIDs)
    let isRestoredProjection =
      restorationID.map {
        settledRestorationIDs.insert($0).inserted
      } ?? false

    // A retained transcript can miss several provider projections while
    // detached. Its first authoritative snapshot after reappearing is a
    // navigation baseline, not a live arrival: settle both new rows and
    // appended content in retained rows before accepting later animation.
    // Hydration can finish after the compact navigation baseline. Its
    // published rows are authoritative even if a newer provider revision
    // is already being projected; waiting for the stream to go quiet
    // would let restored text animate on its first native frame.
    if awaitsPresentationBaseline || isRestoredProjection {
      let publishedSinceBoundary =
        projectionRevision != nil
        && baselineProjectionRevision != nil
        && projectionRevision != baselineProjectionRevision
      guard isRestoredProjection || !initialProjectionIsPending || publishedSinceBoundary else {
        if baselineProjectionRevision == nil { baselineProjectionRevision = projectionRevision }
        return
      }
      awaitsPresentationBaseline = false
      hasObservedProjection = true
      knownProjectedStreamIDs.formUnion(current)
      for coordinator in coordinators.values { coordinator.reset() }
      presentation.settleProjectedStreams(current)
      return
    }

    guard hasObservedProjection else {
      // An asynchronously projected transcript first configures its
      // native surface with an empty active-row placeholder. Waiting
      // here makes the first authoritative projection the navigation
      // baseline instead of mistaking already-present text for live
      // output when that projection arrives.
      guard !initialProjectionIsPending else { return }
      hasObservedProjection = true
      knownProjectedStreamIDs.formUnion(current)
      presentation.settleUnpresentedStreams(current)
      return
    }

    let newlyProjected = current.subtracting(knownProjectedStreamIDs)
    knownProjectedStreamIDs.formUnion(current)
    guard !newlyProjected.isEmpty else { return }
    if animatesNewStreams && !isPlaybackSuspended {
      presentation.reserveInitialAnimations(for: newlyProjected)
    } else {
      presentation.settleUnpresentedStreams(newlyProjected)
    }
  }

  /// Hidden arrivals are navigation state. Rebaseline retained rows as well
  /// as new rows when the next authoritative foreground snapshot arrives.
  public func suspendPlayback() {
    guard !isPlaybackSuspended else { return }
    isPlaybackSuspended = true
    for coordinator in coordinators.values { coordinator.reset() }
    presentation.settleProjectedStreams(knownProjectedStreamIDs)
  }

  public func resumePlayback() {
    guard isPlaybackSuspended else { return }
    isPlaybackSuspended = false
    prepareForPresentation()
  }

}

private struct StreamingTextAnimationRegistryKey: EnvironmentKey {
  static let defaultValue: StreamingTextAnimationRegistry? = nil
}

public extension EnvironmentValues {
  var streamingTextAnimationRegistry: StreamingTextAnimationRegistry? {
    get { self[StreamingTextAnimationRegistryKey.self] }
    set { self[StreamingTextAnimationRegistryKey.self] = newValue }
  }
}

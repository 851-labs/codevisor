import SwiftUI

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

  public func prepareForPresentation() {
    awaitsPresentationBaseline = true
    baselineProjectionRevision = lastProjectionRevision
  }

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

  public func observeHiddenStreams<S: Sequence>(_ streamIDs: S) where S.Element == String {
    presentation.settleUnpresentedStreams(streamIDs)
  }

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

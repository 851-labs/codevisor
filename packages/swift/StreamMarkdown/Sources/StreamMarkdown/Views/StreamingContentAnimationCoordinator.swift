import Foundation
import Observation
import SwiftUI

/// A response-wide animation clock shared by multiple Markdown slices and
/// native elements such as attachment previews. Sharing this object keeps
/// every surface on one document-order cadence instead of restarting at each
/// renderer boundary.
@MainActor
@Observable
public final class StreamingContentAnimationCoordinator {
  public private(set) var hasActiveEntranceAnimation = false
  /// Native text coordinators include this in their prepared snapshot key so
  /// shifted deadlines restart the platform frame clock after foregrounding.
  public private(set) var playbackRevision = 0
  let timeline = StreamingTextAnimationTimeline()
  private var pendingEntranceSourceIDs: Set<String> = []

  public init() {
    timeline.observeActivity { [weak self] active in
      self?.hasActiveEntranceAnimation = active
    }
  }

  public func waitUntilIdle() async throws {
    try await timeline.waitUntilIdle()
  }

  /// Waits until the shared clock is idle and every mounted Markdown slice
  /// has finished its pending structural entrances. The extra stable pass
  /// lets SwiftUI deliver a newly-rendered child's preference before a
  /// provider-completion task decides that the response can be finalized.
  public func waitUntilFullyIdle() async throws {
    await Task.yield()
    while true {
      try await timeline.waitUntilIdle()
      try Task.checkCancellation()
      await Task.yield()
      guard pendingEntranceSourceIDs.isEmpty else {
        try await Task.sleep(for: .milliseconds(1))
        continue
      }

      await Task.yield()
      try Task.checkCancellation()
      guard pendingEntranceSourceIDs.isEmpty else { continue }
      try await timeline.waitUntilIdle()
      guard pendingEntranceSourceIDs.isEmpty else { continue }
      return
    }
  }

  public func scheduleElementEntrance() {
    timeline.scheduleBlockEntrance()
  }

  public func reset() {
    timeline.reset()
  }

  func suspendPlayback() {
    guard timeline.suspend() else { return }
    playbackRevision &+= 1
  }

  func resumePlayback() {
    guard timeline.resume() else { return }
    playbackRevision &+= 1
  }

  func setPendingEntrance(_ pending: Bool, sourceID: String) {
    if pending {
      pendingEntranceSourceIDs.insert(sourceID)
    } else {
      pendingEntranceSourceIDs.remove(sourceID)
    }
  }

  public static var elementEntranceAnimation: Animation {
    .timingCurve(
      StreamingTextAnimationSpec.fadeCurveX1,
      StreamingTextAnimationSpec.fadeCurveY1,
      StreamingTextAnimationSpec.fadeCurveX2,
      StreamingTextAnimationSpec.fadeCurveY2,
      duration: StreamingTextAnimationSpec.fadeDuration
    )
  }
}

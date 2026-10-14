import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class StreamingContentAnimationCoordinator {
  public private(set) var hasActiveEntranceAnimation = false
  public private(set) var playbackRevision = 0
  let timeline = StreamingTextAnimationTimeline()
  private var pendingEntranceSourceIDs: Set<String> = []

  private let sleep: @Sendable (Duration) async throws -> Void

  public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
    self.sleep = sleep
    timeline.observeActivity { [weak self] active in
      self?.hasActiveEntranceAnimation = active
    }
  }

  public func waitUntilIdle() async throws {
    try await timeline.waitUntilIdle()
  }

  public func waitUntilFullyIdle() async throws {
    await Task.yield()
    while true {
      try await timeline.waitUntilIdle()
      try Task.checkCancellation()
      await Task.yield()
      guard pendingEntranceSourceIDs.isEmpty else {
        try await sleep(.milliseconds(1))
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
    playbackRevision &+= 1
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

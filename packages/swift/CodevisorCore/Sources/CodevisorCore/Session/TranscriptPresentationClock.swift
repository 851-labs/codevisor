import Foundation
import Observation

/// Elects one native display clock for a transcript visible in multiple surfaces.
/// Owns registrations, pending-frame scheduling and the visibility count; the
/// session binds presentation operations to its current model.
@MainActor
@Observable
public final class TranscriptPresentationClock {
  public private(set) var revision: UInt64 = 0
  @ObservationIgnored private(set) var visibleViewCount = 0
  @ObservationIgnored private var drivers: [TranscriptFrameDriverToken: TranscriptFrameDriver] = [:]
  @ObservationIgnored private var electedDriver: TranscriptFrameDriverToken?
  @ObservationIgnored private var framePending = false
  @ObservationIgnored private var fallbackTask: Task<Void, Never>?
  @ObservationIgnored private let present: () -> Void
  @ObservationIgnored private let preferPending: () -> Void
  @ObservationIgnored private let reschedulePending: () -> Void
  @ObservationIgnored private let onAppear: () -> Void
  @ObservationIgnored private let onDisappear: () -> Void

  init(
    present: @escaping () -> Void,
    preferPending: @escaping () -> Void,
    reschedulePending: @escaping () -> Void,
    onAppear: @escaping () -> Void,
    onDisappear: @escaping () -> Void
  ) {
    self.present = present
    self.preferPending = preferPending
    self.reschedulePending = reschedulePending
    self.onAppear = onAppear
    self.onDisappear = onDisappear
  }

  /// Transcript-view lifecycle, forwarded to the model to tune its stream
  /// flush cadence. Reference-counted: a session can be visible in several
  /// windows or splits at once.
  public func viewDidAppear() {
    visibleViewCount += 1
    onAppear()
  }

  public func viewDidDisappear() {
    guard visibleViewCount > 0 else { return }
    visibleViewCount -= 1
    onDisappear()
  }

  /// Registers a visible native surface. `requestFrame` must merely arm its
  /// paused display link; all transcript work happens when that link fires.
  public func registerDriver(
    maximumFramesPerSecond: Int,
    requestFrame: @escaping @MainActor () -> Void
  ) -> TranscriptFrameDriverToken {
    let token = TranscriptFrameDriverToken()
    drivers[token] = TranscriptFrameDriver(
      maximumFramesPerSecond: max(1, maximumFramesPerSecond),
      requestFrame: requestFrame
    )
    electDriver()
    if framePending {
      self.requestFrame()
    } else {
      preferPending()
    }
    return token
  }

  public func unregisterDriver(_ token: TranscriptFrameDriverToken) {
    let wasElected = electedDriver == token
    drivers.removeValue(forKey: token)
    if wasElected {
      electedDriver = nil
      electDriver()
    }
    if wasElected, framePending {
      requestFrame()
    }
    if wasElected {
      reschedulePending()
    }
  }

  /// Called by a registered native display link. Non-elected callbacks are
  /// ignored so two windows on unrelated display clocks cannot double-commit
  /// one session inside a single physical frame.
  public func didFire(_ token: TranscriptFrameDriverToken) {
    guard token == electedDriver,
      drivers[token] != nil,
      framePending
    else { return }
    fallbackTask?.cancel()
    fallbackTask = nil
    framePending = false
    present()
    revision &+= 1
  }

  /// Arms the elected display link. Projection workers also call this after
  /// preparing a new immutable row snapshot, so publication is gated by the
  /// same clock as ACP event application.
  @discardableResult
  public func requestFrame() -> Bool {
    framePending = true
    electDriver()
    if let electedDriver,
      let driver = drivers[electedDriver]
    {
      fallbackTask?.cancel()
      fallbackTask = nil
      driver.requestFrame()
      return true
    }

    // A surface can become observable just before AppKit/UIKit attaches it
    // to a window. Preserve progress during that short gap without making
    // the ordinary visible path timer-driven.
    guard fallbackTask == nil else { return true }
    fallbackTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, let self,
        self.framePending
      else { return }
      self.fallbackTask = nil
      self.framePending = false
      self.present()
      self.revision &+= 1
    }
    return true
  }

  private func electDriver() {
    if let electedDriver,
      let elected = drivers[electedDriver],
      drivers.values.allSatisfy({
        $0.maximumFramesPerSecond <= elected.maximumFramesPerSecond
      })
    {
      return
    }
    electedDriver =
      drivers.max {
        $0.value.maximumFramesPerSecond < $1.value.maximumFramesPerSecond
      }?.key
  }
}

/// Opaque registration for one native transcript surface's display clock.
/// The clock elects the fastest visible registration as the session's
/// presentation driver.
public struct TranscriptFrameDriverToken: Hashable, Sendable {
  fileprivate let rawValue = UUID()
}

private struct TranscriptFrameDriver {
  let maximumFramesPerSecond: Int
  let requestFrame: @MainActor () -> Void
}

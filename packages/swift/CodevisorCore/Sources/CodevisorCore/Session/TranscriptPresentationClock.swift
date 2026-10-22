import Foundation
import Observation

@MainActor
@Observable
public final class TranscriptPresentationClock {
  public private(set) var revision: UInt64 = 0
  @ObservationIgnored private(set) var visibleViewCount = 0
  @ObservationIgnored private var drivers: [TranscriptFrameDriverToken: TranscriptFrameDriver] = [:]
  @ObservationIgnored private var electedDriver: TranscriptFrameDriverToken?
  @ObservationIgnored private var framePending = false
  @ObservationIgnored private var fallbackTask: Task<Void, Never>?
  @ObservationIgnored private var presentObservers: [UUID: @MainActor () -> Void] = [:]
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

  public func viewDidAppear() {
    visibleViewCount += 1
    onAppear()
  }

  public func viewDidDisappear() {
    guard visibleViewCount > 0 else { return }
    visibleViewCount -= 1
    onDisappear()
  }

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
    notifyPresentObservers()
  }

  public func addPresentObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    presentObservers[id] = observer
    return id
  }

  public func removePresentObserver(_ id: UUID) {
    presentObservers.removeValue(forKey: id)
  }

  private func notifyPresentObservers() {
    for observer in presentObservers.values { observer() }
  }

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
      self.notifyPresentObservers()
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

public struct TranscriptFrameDriverToken: Hashable, Sendable {
  fileprivate let rawValue = UUID()
}

private struct TranscriptFrameDriver {
  let maximumFramesPerSecond: Int
  let requestFrame: @MainActor () -> Void
}

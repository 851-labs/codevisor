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
  @ObservationIgnored private var presentObservers: [UUID: @MainActor () -> Void] = [:]
  @ObservationIgnored private let present: () -> Void
  @ObservationIgnored private let preferPending: () -> Void
  @ObservationIgnored private let onAppear: () -> Void
  @ObservationIgnored private let onDisappear: () -> Void

  init(
    present: @escaping () -> Void,
    preferPending: @escaping () -> Void,
    onAppear: @escaping () -> Void,
    onDisappear: @escaping () -> Void
  ) {
    self.present = present
    self.preferPending = preferPending
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
    isVisible: Bool,
    requestFrame: @escaping @MainActor () -> Void
  ) -> TranscriptFrameDriverToken {
    let token = TranscriptFrameDriverToken()
    drivers[token] = TranscriptFrameDriver(
      maximumFramesPerSecond: max(1, maximumFramesPerSecond),
      isVisible: isVisible,
      requestFrame: requestFrame
    )
    driversDidChange()
    if isVisible, !framePending { preferPending() }
    return token
  }

  public func setDriver(_ token: TranscriptFrameDriverToken, isVisible: Bool) {
    guard drivers[token]?.isVisible == !isVisible else { return }
    drivers[token]?.isVisible = isVisible
    driversDidChange()
    if isVisible, !framePending { preferPending() }
  }

  public func unregisterDriver(_ token: TranscriptFrameDriverToken) {
    guard drivers.removeValue(forKey: token) != nil else { return }
    driversDidChange()
  }

  public func didFire(_ token: TranscriptFrameDriverToken) {
    guard token == electedDriver, framePending else { return }
    presentFrame()
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
    guard let electedDriver, let driver = drivers[electedDriver] else {
      presentFrame()
      return true
    }
    driver.requestFrame()
    return true
  }

  private func driversDidChange() {
    let previous = electedDriver
    electDriver()
    guard framePending, electedDriver != previous else { return }
    requestFrame()
  }

  private func electDriver() {
    let visible = drivers.filter { $0.value.isVisible }
    if let electedDriver,
      let elected = visible[electedDriver],
      visible.values.allSatisfy({ $0.maximumFramesPerSecond <= elected.maximumFramesPerSecond })
    {
      return
    }
    electedDriver = visible.max { $0.value.maximumFramesPerSecond < $1.value.maximumFramesPerSecond }?.key
  }

  private func presentFrame() {
    framePending = false
    present()
    revision &+= 1
    notifyPresentObservers()
  }
}

public struct TranscriptFrameDriverToken: Hashable, Sendable {
  fileprivate let rawValue = UUID()
}

private struct TranscriptFrameDriver {
  let maximumFramesPerSecond: Int
  var isVisible: Bool
  let requestFrame: @MainActor () -> Void
}

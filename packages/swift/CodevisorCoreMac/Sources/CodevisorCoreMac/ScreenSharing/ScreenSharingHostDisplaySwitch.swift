import Foundation

@MainActor
final class ScreenSharingHostDisplaySwitch {
  let target: String
  private(set) var isFinished = false
  private(set) var isSuperseded = false
  var failure: String?
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  init(target: String) {
    self.target = target
  }

  var isMoving: Bool { !isFinished && !isSuperseded }

  func wait(atMost limit: Duration) async {
    guard isMoving else { return }

    let id = UUID()
    let timer = Task { [weak self] in
      guard (try? await Task.sleep(for: limit)) != nil else { return }

      self?.waiters.removeValue(forKey: id)?.resume()
    }
    await withCheckedContinuation { waiters[id] = $0 }
    timer.cancel()
  }

  func finish() {
    isFinished = true
    resumeWaiters()
  }

  func supersede() {
    isSuperseded = true
    resumeWaiters()
  }

  private func resumeWaiters() {
    let waiting = waiters.values
    waiters = [:]
    for waiter in waiting { waiter.resume() }
  }
}

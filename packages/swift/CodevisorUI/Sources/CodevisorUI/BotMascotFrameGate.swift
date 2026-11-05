import Synchronization

final class BotMascotFrameGate: Sendable {
  private let isBusy = Mutex(false)

  func enter() -> Bool {
    isBusy.withLock { isBusy in
      guard !isBusy else { return false }

      isBusy = true
      return true
    }
  }

  func leave() {
    isBusy.withLock { $0 = false }
  }
}

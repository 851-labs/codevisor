import Foundation
import CodevisorCore

/// Adapts the existing authenticated Unix socket to the main-actor media host.
/// The socket's client queue may wait; the app's main thread never blocks.
final class NativeScreenSharingBridge: @unchecked Sendable {
  @MainActor private var host: ScreenSharingHostService?
  @MainActor private var hostGeneration = 0
  /// Live views of Computer Use windows (`computer-use:` targets). Separate
  /// from display sharing: view-only, several viewers, no exclusive lease.
  @MainActor private var computerUseHost: ComputerUseLivePreviewHost?
  @MainActor private var computerUseObservation: UUID?
  private let lock = NSLock()
  private var generation = 0
  private var enabled = false

  func start() {
    lock.withLock {
      generation += 1; enabled = true
    }
  }

  func request(_ data: Data) throws -> Data {
    let generation = try lock.withLock {
      guard enabled else { throw BridgeError("Screen Sharing host is stopped.") }
      return self.generation
    }
    let result = Reply()
    let task = Task { @MainActor in
      do {
        try Task.checkCancellation()
        guard self.lock.withLock({ self.enabled && self.generation == generation }) else {
          throw BridgeError("Screen Sharing host is stopped.")
        }
        let request = try JSONDecoder().decode(ServerScreenSharingRequest.self, from: data)
        if self.hostGeneration != generation {
          let previous = self.host
          self.host = nil
          self.shutdownComputerUseHost()
          await previous?.shutdown()
          guard self.lock.withLock({ self.enabled && self.generation == generation }) else {
            throw BridgeError("Screen Sharing host is stopped.")
          }
        }
        self.hostGeneration = generation
        if request.displayId?.hasPrefix(ComputerUseStreamTarget.prefix) == true {
          let host = self.computerUseHost ?? self.makeComputerUseHost()
          result.finish(.success(try JSONEncoder().encode(await host.handle(request))))
          return
        }
        let host = self.host ?? ScreenSharingHostService()
        self.host = host
        result.finish(.success(try JSONEncoder().encode(await host.handle(request))))
      } catch { result.finish(.failure(error)) }
    }
    do { return try result.wait() } catch { task.cancel(); throw error }
  }

  func stop() {
    let generation = lock.withLock {
      enabled = false; return self.generation
    }
    Task { @MainActor in
      guard self.hostGeneration == generation else { return }
      let host = self.host
      self.host = nil
      self.shutdownComputerUseHost()
      await host?.shutdown()
    }
  }

  @MainActor private func makeComputerUseHost() -> ComputerUseLivePreviewHost {
    let host = ComputerUseLivePreviewHost()
    computerUseHost = host
    computerUseObservation = ComputerUseLivePreview.shared.observe { [weak host] in
      host?.activityChanged()
    }
    return host
  }

  @MainActor private func shutdownComputerUseHost() {
    if let computerUseObservation { ComputerUseLivePreview.shared.stopObserving(computerUseObservation) }
    computerUseObservation = nil
    computerUseHost?.shutdown()
    computerUseHost = nil
  }

  private final class Reply: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Result<Data, any Error>?
    func finish(_ value: Result<Data, any Error>) {
      condition.lock(); defer { condition.unlock() }
      guard self.value == nil else { return }
      self.value = value
      condition.broadcast()
    }
    func wait() throws -> Data {
      condition.lock(); defer { condition.unlock() }
      let deadline = Date().addingTimeInterval(25)
      while value == nil {
        guard condition.wait(until: deadline) else { throw BridgeError("Screen Sharing host timed out.") }
      }
      return try value!.get()
    }
  }
}

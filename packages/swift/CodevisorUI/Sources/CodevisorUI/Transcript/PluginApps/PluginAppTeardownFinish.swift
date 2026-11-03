@MainActor
final class PluginAppTeardownFinish {
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

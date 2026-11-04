import Synchronization

public final class ResumeOnce<Value: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<Value, Never>?>

  public init(_ continuation: CheckedContinuation<Value, Never>) {
    self.continuation = Mutex(continuation)
  }

  @discardableResult
  public func resume(with value: Value) -> Bool {
    let pending = continuation.withLock { pending in
      defer { pending = nil }
      return pending
    }
    pending?.resume(returning: value)
    return pending != nil
  }
}

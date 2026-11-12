import Foundation

@MainActor
public enum ScreenSharingRace {
  public static func value<Value: Sendable>(
    of work: @escaping @Sendable () async throws -> Value,
    before deadline: @escaping @Sendable () async throws -> Void,
    cancellingLateWork: Bool = true
  ) async throws -> Value? {
    let race = Race<Value>()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.start(work: work, deadline: deadline, continuation: continuation)
      }
    } onCancel: {
      guard cancellingLateWork else { return }
      Task { @MainActor in race.abandon() }
    }
    race.finish(cancellingWork: result == nil && cancellingLateWork)
    return try result?.get()
  }
}

@MainActor
private final class Race<Value: Sendable> {
  private var continuation: CheckedContinuation<Result<Value, any Error>?, Never>?
  private var work: Task<Void, Never>?
  private var timer: Task<Void, Never>?

  func start(
    work: @escaping @Sendable () async throws -> Value, deadline: @escaping @Sendable () async throws -> Void,
    continuation: CheckedContinuation<Result<Value, any Error>?, Never>
  ) {
    self.continuation = continuation
    self.work = Task { @MainActor in
      do { self.resume(.success(try await work())) } catch { self.resume(.failure(error)) }
    }
    timer = Task { @MainActor in
      guard (try? await deadline()) != nil else { return }
      self.resume(nil)
    }
  }

  func abandon() {
    work?.cancel()
    resume(.failure(CancellationError()))
  }

  func finish(cancellingWork: Bool) {
    timer?.cancel()
    if cancellingWork { work?.cancel() }
  }

  private func resume(_ result: Result<Value, any Error>?) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

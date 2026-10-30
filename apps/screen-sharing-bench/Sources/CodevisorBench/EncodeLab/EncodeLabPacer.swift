import Dispatch

final class EncodeLabPacer: Sendable {
  private let queue = DispatchQueue(label: "codevisor.bench.encode-lab", qos: .userInteractive)

  func run(
    atNs deadline: Int64, _ work: @escaping @Sendable () throws -> EncodeLabSubmission
  ) async throws -> EncodeLabSubmission {
    try await withCheckedThrowingContinuation { finished in
      let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
      timer.schedule(deadline: DispatchTime(uptimeNanoseconds: UInt64(max(0, deadline))), leeway: .nanoseconds(0))
      timer.setEventHandler {
        timer.cancel()
        finished.resume(with: Result { try work() })
      }
      timer.activate()
    }
  }
}

import Foundation

/// One preparation in flight and one replaceable waiting input. A continuous
/// stream can publish useful results without waiting for silence, while fast
/// producers cannot accumulate an unbounded queue of obsolete layout work.
@MainActor
public final class LatestValuePreparationWorker<Input: Sendable, Output: Sendable> {
  private struct Work {
    let generation: UInt64
    let input: Input
    let completion: @MainActor (Input, Result<Output, Error>) -> Void
  }

  private let prepare: @Sendable (Input) throws -> Output
  private var generation: UInt64 = 0
  private var pending: Work?
  private var processing: Task<Void, Never>?

  public init(prepare: @escaping @Sendable (Input) throws -> Output) {
    self.prepare = prepare
  }

  public func submit(
    _ input: Input,
    completion: @escaping @MainActor (Input, Result<Output, Error>) -> Void
  ) {
    pending = Work(generation: generation, input: input, completion: completion)
    startIfNeeded()
  }

  public func cancel() {
    generation &+= 1
    pending = nil
    processing?.cancel()
  }

  private func startIfNeeded() {
    guard processing == nil, pending != nil else { return }
    processing = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled, let work = pending {
        pending = nil
        let prepare = prepare
        let input = work.input
        let task = Task.detached(priority: .userInitiated) { try prepare(input) }
        let result = await withTaskCancellationHandler {
          await task.result
        } onCancel: {
          task.cancel()
        }
        guard !Task.isCancelled else { break }
        if work.generation == generation { work.completion(work.input, result) }
      }
      processing = nil
      startIfNeeded()
    }
  }
}

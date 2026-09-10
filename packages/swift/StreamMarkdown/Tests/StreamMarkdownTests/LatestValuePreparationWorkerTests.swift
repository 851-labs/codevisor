import CodevisorTestSupport
import Foundation
import MarkdownCore
import Synchronization
import Testing

@MainActor
struct LatestValuePreparationWorkerTests {
  @Test func runningWorkPublishesAndOnlyLatestPendingInputRuns() async {
    let started = TestSignal()
    let published = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let inputs = Mutex<[Int]>([])
    let worker = LatestValuePreparationWorker<Int, Int> { value in
      inputs.withLock { $0.append(value) }
      if value == 1 { started.signal(); release.wait() }
      return value
    }
    var outputs: [Int] = []
    func completed(_ input: Int, _ result: Result<Int, Error>) {
      if case let .success(value) = result { outputs.append(value) }
      published.signal()
    }
    worker.submit(1, completion: completed)
    await started.wait()
    worker.submit(2, completion: completed)
    worker.submit(3, completion: completed)
    release.signal()
    await published.wait(for: 2)
    #expect(outputs == [1, 3])
    #expect(inputs.withLock { $0 } == [1, 3])
    worker.cancel()
  }

  @Test func cancellationRejectsOldOutputAndAllowsANewPresentation() async {
    let started = TestSignal()
    let published = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let worker = LatestValuePreparationWorker<Int, Int> { value in
      if value == 1 { started.signal(); release.wait() }
      return value
    }
    worker.submit(1) { _, _ in Issue.record("Cancelled presentation published") }
    await started.wait()
    worker.cancel()
    worker.submit(2) { input, result in
      #expect(input == 2)
      if case let .success(value) = result { #expect(value == 2) } else { Issue.record("New presentation failed") }
      published.signal()
    }
    release.signal()
    await published.wait()
    worker.cancel()
  }
}

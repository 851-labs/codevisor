import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

private final class RunLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String] = []
  func append(_ entry: String) { lock.withLock { entries.append(entry) } }
  var values: [String] { lock.withLock { entries } }
}

@Suite("CoalescingWorkQueue")
struct CoalescingWorkQueueTests {
  @Test("A burst for one key runs the job in flight and then only the newest")
  func coalescesPendingJobsPerKey() async {
    let queue = CoalescingWorkQueue(label: "test.coalescing")
    let log = RunLog()
    let started = TestSignal()
    let release = DispatchSemaphore(value: 0)
    queue.enqueue(key: "status") {
      log.append("status-0")
      started.signal()
      release.wait()
    }
    // The first write is in flight; everything below queues behind it.
    await started.wait()
    for index in 1...50 {
      queue.enqueue(key: "status") { log.append("status-\(index)") }
    }
    queue.enqueue(key: "channel") { log.append("channel") }
    queue.enqueue(key: "status") { log.append("status-final") }
    release.signal()
    await queue.flush()

    // Keys keep first-enqueue order; each runs only its newest job.
    #expect(log.values == ["status-0", "status-final", "channel"])
  }

  @Test("perform runs after every job enqueued before it")
  func performIsOrderedAfterEarlierJobs() async {
    let queue = CoalescingWorkQueue(label: "test.coalescing.perform")
    let log = RunLog()
    queue.enqueue(key: "draft") { log.append("write") }
    let observed = await queue.perform { log.values }
    #expect(observed == ["write"])
  }
}

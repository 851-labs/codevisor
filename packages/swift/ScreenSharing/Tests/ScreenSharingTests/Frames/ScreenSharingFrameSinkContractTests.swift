import Foundation
import ScreenSharingTesting
import Testing

@testable import ScreenSharing

/// `ScreenSharingFrameSink` is write-only, so every implementation owes the same unwritten
/// promises: order, a declared drop policy, and silence after teardown. The list lives in
/// `ScreenSharingTesting` as data, and each case runs as its own test here, so a WebRTC sink can
/// later be held to the same list instead of to a second description of it.
struct ScreenSharingFrameSinkContractTests {
  @Test(arguments: ScreenSharingFrameSinkContract.all)
  func theNewestWinsMailboxSinkKeepsTheContract(_ contract: ScreenSharingFrameSinkContract) throws {
    try contract.check(ScreenSharingMailboxFrameSink())
  }

  @Test(arguments: ScreenSharingFrameSinkContract.all)
  func theRecordingSinkKeepsTheContract(_ contract: ScreenSharingFrameSinkContract) throws {
    try contract.check(ScreenSharingRecordingFrameSink())
  }

  /// A contract list that nothing can fail proves nothing. Each of these sinks breaks one promise
  /// while keeping the others, so at least one case must reject it.
  @Test func theContractRejectsASinkThatBreaksAPromise() {
    for policy in [BrokenSink.Policy.keepOldest, .ignoreTeardown] {
      // A fresh subject per case: a contract is never handed a sink another one already used.
      let rejecting = ScreenSharingFrameSinkContract.all.filter { contract in
        (try? contract.check(BrokenSink(policy: policy))) == nil
      }
      #expect(!rejecting.isEmpty, "\(policy) satisfied every contract")
    }
  }

  /// Claims `.newestFrame` but keeps the oldest frame, or keeps delivering after teardown.
  private final class BrokenSink: ScreenSharingFrameSink, ScreenSharingFrameSinkSubject, @unchecked Sendable {
    enum Policy { case keepOldest, ignoreTeardown }

    private let lock = NSLock()
    private let policy: Policy
    private var held: [Int64] = []
    private var drops = 0

    init(policy: Policy) { self.policy = policy }

    var sink: any ScreenSharingFrameSink { self }
    var retention: ScreenSharingFrameSinkRetention { policy == .keepOldest ? .newestFrame : .everyFrame }
    var droppedCount: Int { lock.withLock { drops } }

    func push(_ frame: ScreenSharingVideoFrame) {
      lock.withLock {
        switch policy {
        case .keepOldest:
          if held.isEmpty { held = [frame.timestampNs] } else { drops += 1 }
        case .ignoreTeardown:
          held.append(frame.timestampNs)
        }
      }
    }

    func takeDelivered() -> [Int64] {
      lock.withLock {
        defer { held = [] }
        return held
      }
    }

    func tearDown() {}
  }
}

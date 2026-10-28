import Foundation
import Testing

@testable import ScreenSharing
@testable import ScreenSharingWebRTC

@Suite struct ScreenSharingFieldTrialsTests {
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var applied: [[String: String]] = []
    var onApply: (@Sendable ([String: String]) -> Void)?
    var count: Int { lock.lock(); defer { lock.unlock() }; return applied.count }
    var last: [String: String]? { lock.lock(); defer { lock.unlock() }; return applied.last }
    func record(_ trials: [String: String]) {
      lock.lock(); applied.append(trials); lock.unlock()
      onApply?(trials)
    }
  }

  @Test func theProductSelectionBoundsThePlayoutDelayAndIsAppliedOnce() {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    #expect(trials.installProduct() == .product)
    #expect(
      recorder.last == [
        "WebRTC-ForcePlayoutDelay": "min_ms:15,max_ms:80", "WebRTC-Video-Pacing": "factor:10",
        "WebRTC-FrameDropper": "Disabled",
      ])
    #expect(trials.installProduct() == .product)
    #expect(trials.ensureInstalled() == .product)
    #expect(recorder.count == 1)
  }

  @Test func theFirstSelectionFixesTheProcess() {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    #expect(trials.ensureInstalled() == .default)
    #expect(recorder.count == 1 && recorder.last == [:])
    #expect(trials.installProduct() == .default)
    #expect(recorder.count == 1)
  }

  @Test func aSecondCallerBlocksAtTheWaitingBoundaryUntilTheApplyReturns() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    let events = EventLog()
    let applyStarted = DispatchSemaphore(value: 0)
    let releaseApply = DispatchSemaphore(value: 0)
    let secondProgressed = DispatchSemaphore(value: 0)
    let secondReturned = DispatchSemaphore(value: 0)
    let firstReturned = DispatchSemaphore(value: 0)

    trials.onWaitingForApply = {
      events.append("secondReachedWait")
      secondProgressed.signal()
    }
    recorder.onApply = { _ in
      events.append("applyStarted")
      applyStarted.signal()
      releaseApply.wait()
      events.append("applyFinished")
    }
    DispatchQueue.global().async {
      trials.installProduct()
      events.append("firstReturned")
      firstReturned.signal()
    }
    applyStarted.wait()
    DispatchQueue.global().async {
      let selection = trials.ensureInstalled()
      events.append("secondReturned(\(selection.name))")
      secondProgressed.signal()
      secondReturned.signal()
    }
    secondProgressed.wait()
    #expect(events.entries.contains("secondReachedWait"))
    #expect(!events.entries.contains { $0.hasPrefix("secondReturned") })
    releaseApply.signal()
    firstReturned.wait()
    secondReturned.wait()
    let recorded = events.entries
    let applyFinished = try #require(recorded.firstIndex(of: "applyFinished"))
    let second = try #require(recorded.firstIndex(of: "secondReturned(product)"))
    let reachedWait = try #require(recorded.firstIndex(of: "secondReachedWait"))
    #expect(reachedWait < applyFinished && applyFinished < second)
    #expect(recorded.first == "applyStarted")
    #expect(recorder.count == 1)
  }

  @Test func concurrentCallersApplyExactlyOnceAndAgreeOnTheResult() {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    let results = EventLog()
    let group = DispatchGroup()
    for index in 0..<8 {
      DispatchQueue.global().async(group: group) {
        let selection = index.isMultiple(of: 2) ? trials.installProduct() : trials.ensureInstalled()
        results.append(selection.name)
      }
    }
    group.wait()
    #expect(recorder.count == 1)
    let entries = results.entries
    #expect(entries.count == 8)
    #expect(Set(entries).count == 1)
  }

  @Test @MainActor func theBootstrapLabelsWhatIsInstalled() {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    trials.installProduct()
    let metrics = ScreenSharingMetrics()
    #expect(ScreenSharingPeer.bootstrapTrials(trials, publishingInto: metrics) == .product)
    #expect(metrics.snapshot().labels["playoutExperiment"] == "WebRTC-ForcePlayoutDelay min_ms:15,max_ms:80")
    #expect(metrics.snapshot().labels["fieldTrialProvenance"] == "product")
    #expect(recorder.count == 1)

    let plainTrials = ScreenSharingFieldTrials(apply: { _ in })
    let plainMetrics = ScreenSharingMetrics()
    #expect(ScreenSharingPeer.bootstrapTrials(plainTrials, publishingInto: plainMetrics) == .default)
    #expect(plainMetrics.snapshot().labels["playoutExperiment"] == nil)
    #expect(plainMetrics.snapshot().labels["fieldTrialProvenance"] == "default")
  }
}

private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
  var entries: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

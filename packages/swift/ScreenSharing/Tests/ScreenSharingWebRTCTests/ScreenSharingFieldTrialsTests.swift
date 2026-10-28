import Foundation
import Testing

@testable import ScreenSharing
@testable import ScreenSharingWebRTC

@Suite struct ScreenSharingFieldTrialsTests {
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var applied: [[String: String]] = []
    var all: [[String: String]] { lock.withLock { applied } }
    func record(_ trials: [String: String]) { lock.withLock { applied.append(trials) } }
  }

  private static let productTrials = [
    "WebRTC-ForcePlayoutDelay": "min_ms:15,max_ms:80", "WebRTC-Video-Pacing": "factor:10",
    "WebRTC-FrameDropper": "Disabled",
  ]
  private static let productString =
    "WebRTC-ForcePlayoutDelay/min_ms:15,max_ms:80/WebRTC-FrameDropper/Disabled/WebRTC-Video-Pacing/factor:10/"

  @Test func everyFactoryInstallsTheProductTrialsOnceAndLabelsThem() {
    let recorder = Recorder()
    let trials = Self.trials(recordingInto: recorder)
    let first = ScreenSharingMetrics()
    let second = ScreenSharingMetrics()
    _ = trials.makeFactory(codecFactory: ScreenSharingCodecFactory(metrics: first), metrics: first)
    _ = trials.makeFactory(codecFactory: ScreenSharingCodecFactory(metrics: second), metrics: second)
    #expect(recorder.all == [Self.productTrials])
    #expect(first.snapshot().labels["fieldTrials"] == Self.productString)
    #expect(second.snapshot().labels["fieldTrials"] == Self.productString)
  }

  @Test func concurrentFactoriesInstallTheTrialsExactlyOnce() {
    let recorder = Recorder()
    let trials = Self.trials(recordingInto: recorder)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      let metrics = ScreenSharingMetrics()
      _ = trials.makeFactory(codecFactory: ScreenSharingCodecFactory(metrics: metrics), metrics: metrics)
    }
    #expect(recorder.all == [Self.productTrials])
  }

  @Test @MainActor func theSenderBuildsItsFactoryThroughTheTrials() async throws {
    let recorder = Recorder()
    let metrics = ScreenSharingMetrics()
    let sender = try await ScreenSharingSender(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: metrics,
      options: Self.options(recordingInto: recorder))
    defer { sender.close() }
    #expect(recorder.all == [Self.productTrials])
    #expect(metrics.snapshot().labels["fieldTrials"] == Self.productString)
  }

  @Test @MainActor func theReceiverBuildsItsFactoryThroughTheTrials() async throws {
    let recorder = Recorder()
    let metrics = ScreenSharingMetrics()
    let receiver = try await ScreenSharingReceiver(
      configuration: .init(), metrics: metrics, options: Self.options(recordingInto: recorder))
    defer { receiver.close() }
    #expect(recorder.all == [Self.productTrials])
    #expect(metrics.snapshot().labels["fieldTrials"] == Self.productString)
  }

  @Test func everyPeerDefaultsToTheProcessTrials() {
    #expect(ScreenSharingPeerOptions().fieldTrials === ScreenSharingFieldTrials.process)
  }

  private static func options(recordingInto recorder: Recorder) -> ScreenSharingPeerOptions {
    var options = ScreenSharingPeerOptions()
    options.fieldTrials = trials(recordingInto: recorder)
    return options
  }

  private static func trials(recordingInto recorder: Recorder) -> ScreenSharingFieldTrials {
    ScreenSharingFieldTrials(apply: {
      recorder.record($0)
      ScreenSharingFieldTrials.process.install()
    })
  }
}

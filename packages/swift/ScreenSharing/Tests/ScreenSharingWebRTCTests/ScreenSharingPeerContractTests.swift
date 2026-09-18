import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

/// The peer's collaborators exercised directly: the option surface a caller
/// configures, the statistics selection, the native delegate's dispatch rules
/// and the renderer's admission rules. None of these needs a negotiated peer.
@MainActor
struct ScreenSharingPeerContractTests {
  /// Delegate callbacks are `@Sendable` and arrive from WebRTC threads, so the
  /// recording has to be safe for that even though these tests call them inline.
  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String] = []
    private var tracks: [String] = []
    private var gathered = 0
    var connectionStates: [String] { lock.withLock { states } }
    var videoTrackIDs: [String] { lock.withLock { tracks } }
    var gatheringCompletions: Int { lock.withLock { gathered } }

    func install(on delegate: ScreenSharingPeerDelegate) {
      delegate.onConnection = { [self] state in lock.withLock { states.append(state) } }
      delegate.onVideoTrack = { [self] track in lock.withLock { tracks.append(track.trackId) } }
      delegate.onGathered = { [self] in lock.withLock { gathered += 1 } }
    }
  }

  private func stagedConnection() throws -> ScreenSharingPeerStaging {
    try ScreenSharingPeerStaging(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: ScreenSharingMetrics(),
      options: ScreenSharingPeerOptions(), connectivity: nil)
  }

  @Test func theDelegateNamesEveryConnectionStateAndReportsGatheringOnlyWhenComplete() throws {
    let staged = try stagedConnection()
    defer { staged.connection.close() }
    let recorder = Recorder()
    recorder.install(on: staged.delegate)
    let states: [RTCPeerConnectionState] = [.new, .connecting, .connected, .disconnected, .failed, .closed]
    for state in states { staged.delegate.peerConnection(staged.connection, didChange: state) }
    #expect(recorder.connectionStates == ["new", "connecting", "connected", "disconnected", "failed", "closed"])

    for state in [RTCIceGatheringState.new, .gathering] {
      staged.delegate.peerConnection(staged.connection, didChange: state)
    }
    #expect(recorder.gatheringCompletions == 0)
    staged.delegate.peerConnection(staged.connection, didChange: RTCIceGatheringState.complete)
    #expect(recorder.gatheringCompletions == 1)

    // Everything the peer does not model is inert: no hook fires for it.
    staged.delegate.peerConnection(staged.connection, didChange: RTCSignalingState.haveLocalOffer)
    staged.delegate.peerConnection(staged.connection, didChange: RTCIceConnectionState.failed)
    staged.delegate.peerConnectionShouldNegotiate(staged.connection)
    staged.delegate.peerConnection(
      staged.connection,
      didGenerate: RTCIceCandidate(sdp: "candidate:0 1 udp 1 1.2.3.4 1 typ host", sdpMLineIndex: 0, sdpMid: "0"))
    staged.delegate.peerConnection(staged.connection, didRemove: [])
    #expect(recorder.connectionStates.count == states.count)
    #expect(recorder.gatheringCompletions == 1)
    #expect(recorder.videoTrackIDs.isEmpty)
  }

  @Test func theDelegateForwardsOnlyVideoReceiversAndRefusesUnnegotiatedChannels() throws {
    let staged = try stagedConnection()
    defer { staged.connection.close() }
    let recorder = Recorder()
    recorder.install(on: staged.delegate)
    let video = try #require(staged.connection.addTransceiver(of: .video))
    let audio = try #require(staged.connection.addTransceiver(of: .audio))
    staged.delegate.peerConnection(staged.connection, didAdd: audio.receiver, streams: [])
    #expect(recorder.videoTrackIDs.isEmpty)
    staged.delegate.peerConnection(staged.connection, didAdd: video.receiver, streams: [])
    #expect(recorder.videoTrackIDs == [try #require(video.receiver.track).trackId])

    // The three protocol channels are negotiated out of band, so a channel the
    // remote opened itself is refused rather than wired to anything.
    let uninvited = try #require(
      staged.connection.dataChannel(forLabel: "uninvited", configuration: RTCDataChannelConfiguration()))
    staged.delegate.peerConnection(staged.connection, didOpen: uninvited)
    #expect(uninvited.readyState != .open && uninvited.readyState != .connecting)
  }

  @Test func peerOptionsCarryTheProductDefaultsAndCompareByValue() throws {
    let options = ScreenSharingPeerOptions()
    #expect(options.codec == .h264 && options.useLowLatencyRateControl)
    #expect(!options.disableLookAhead && !options.staticCodecRate && !options.completeEachFrame)
    #expect(!options.prioritizeSpeed && !options.maintainSourceRate)
    #expect(options.maximumPendingFrames == 2 && options.keyframeIntervalSeconds == 2)
    // Every experiment threshold is absent by default, which means "the product".
    #expect(options.transportCeilingBps == nil && options.sourceIdleThresholdNs == nil)
    #expect(options.deliveryGrace == nil && options.deliveryGraceExtensions == nil)
    #expect(options == ScreenSharingPeerOptions())
    var altered = options
    altered.deliveryGraceExtensions = 0
    #expect(altered != options)
  }

  @Test func aDiagnosticTransportCeilingMustCoverTheBitrateAndStayUnderHalfAGigabit() throws {
    let configuration = try ScreenSharingVideoConfiguration(width: 640, height: 480, bitrate: 4_000_000)
    #expect(try configuration.validatingTransportCeiling(nil) == nil)
    #expect(try configuration.validatingTransportCeiling(4_000_000) == 4_000_000)
    #expect(try configuration.validatingTransportCeiling(500_000_000) == 500_000_000)
    #expect(throws: ScreenSharingError.self) { try configuration.validatingTransportCeiling(3_999_999) }
    #expect(throws: ScreenSharingError.self) { try configuration.validatingTransportCeiling(500_000_001) }
  }

  @Test func statisticsKeepTheNegotiatedPairItsCandidatesAndTheAllowedFieldsOnly() {
    let entries: [ScreenSharingPeerStatistics.Entry] = [
      .init(
        id: "T", type: "transport", values: ["selectedCandidatePairId": "P1" as NSString, "bytesSent": 9 as NSNumber]),
      .init(
        id: "P1", type: "candidate-pair",
        values: [
          "localCandidateId": "L1" as NSString, "remoteCandidateId": "R1" as NSString,
          "currentRoundTripTime": 0.25 as NSNumber, "state": "succeeded" as NSString, "nominated": true as NSNumber,
        ]),
      .init(
        id: "P2", type: "candidate-pair",
        values: [
          "state": "succeeded" as NSString, "nominated": true as NSNumber, "currentRoundTripTime": 9 as NSNumber,
        ]),
      .init(id: "L1", type: "local-candidate", values: ["candidateType": "host" as NSString]),
      .init(id: "R1", type: "remote-candidate", values: ["candidateType": "srflx" as NSString]),
      .init(id: "L9", type: "local-candidate", values: ["candidateType": "relay" as NSString]),
      .init(id: "O", type: "outbound-rtp", values: ["framesEncoded": 12 as NSNumber, "targetBitrate": 1 as NSNumber]),
      .init(id: "M", type: "media-source", values: ["framesPerSecond": 60 as NSNumber]),
    ]
    let values = ScreenSharingPeerStatistics.values(entries)
    // The selected pair and the two candidates it names, and nothing else.
    #expect(values["candidate-pair.P1.currentRoundTripTime"] == "0.25")
    #expect(values["candidate-pair.P1.state"] == "succeeded" && values["candidate-pair.P1.nominated"] == "1")
    #expect(values["local-candidate.L1.candidateType"] == "host")
    #expect(values["remote-candidate.R1.candidateType"] == "srflx")
    #expect(values["candidate-pair.P2.currentRoundTripTime"] == nil)
    #expect(values["local-candidate.L9.candidateType"] == nil)
    // A transport is never reported, an unlisted type is dropped whole, and an
    // unlisted field is dropped from a type that is otherwise reported.
    #expect(values["transport.T.bytesSent"] == nil)
    #expect(values["media-source.M.framesPerSecond"] == nil)
    #expect(values["outbound-rtp.O.framesEncoded"] == "12")
    #expect(values["outbound-rtp.O.targetBitrate"] == nil)
  }

  @Test func statisticsFallBackToTheNominatedPairWhenNoTransportNamesOne() {
    let pairs: [ScreenSharingPeerStatistics.Entry] = [
      .init(
        id: "P1", type: "candidate-pair",
        values: [
          "state": "succeeded" as NSString, "nominated": true as NSNumber, "localCandidateId": "L1" as NSString,
          "packetsSent": 4 as NSNumber,
        ]),
      .init(
        id: "P2", type: "candidate-pair",
        values: ["state": "failed" as NSString, "nominated": true as NSNumber, "packetsSent": 5 as NSNumber]),
      .init(
        id: "P3", type: "candidate-pair",
        values: ["state": "succeeded" as NSString, "nominated": false as NSNumber, "packetsSent": 6 as NSNumber]),
      .init(id: "L1", type: "local-candidate", values: ["protocol": "udp" as NSString]),
    ]
    let values = ScreenSharingPeerStatistics.values(pairs)
    #expect(values["candidate-pair.P1.packetsSent"] == "4")
    // Nomination alone is not enough, and neither is a succeeded state alone.
    #expect(values["candidate-pair.P2.packetsSent"] == nil && values["candidate-pair.P3.packetsSent"] == nil)
    #expect(values["local-candidate.L1.protocol"] == "udp")

    // Without any usable pair no candidate is reported either.
    let unusable = ScreenSharingPeerStatistics.values(Array(pairs[1...]))
    #expect(unusable.isEmpty)
    #expect(ScreenSharingPeerStatistics.values([]).isEmpty)
  }

  @Test func theRendererAdmitsOnlyUprightNativeFramesAndKeepsTheNewestOne() throws {
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    let renderer = ScreenSharingPeerRenderer(mailbox: mailbox, metrics: metrics)
    func pixelBuffer(identity: Int64) throws -> CVPixelBuffer {
      var pixel: CVPixelBuffer?
      #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
      let buffer = try #require(pixel)
      ScreenSharingFrameIdentity.attach(sourceTimestampNs: identity, to: buffer)
      return buffer
    }
    func frame(identity: Int64, rotation: RTCVideoRotation = ._0, timeStampNs: Int64) throws -> RTCVideoFrame {
      RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: try pixelBuffer(identity: identity)), rotation: rotation,
        timeStampNs: timeStampNs)
    }

    renderer.renderFrame(nil)
    renderer.renderFrame(try frame(identity: 1, rotation: ._90, timeStampNs: 1))
    // Rotation is never applied downstream, so a rotated frame would be wrong
    // rather than late; a non-native buffer would mean the bridge changed.
    renderer.renderFrame(RTCVideoFrame(buffer: RTCI420Buffer(width: 16, height: 16), rotation: ._0, timeStampNs: 2))
    #expect(metrics.snapshot().counters["receivedFrames"] == nil)
    #expect(!mailbox.isHolding)

    renderer.renderFrame(try frame(identity: 10, rotation: ._0, timeStampNs: 10))
    renderer.renderFrame(try frame(identity: 20, rotation: ._0, timeStampNs: 20))
    #expect(metrics.snapshot().counters["receivedFrames"] == 2)
    // Newest wins: the older frame is counted as dropped rather than queued.
    #expect(mailbox.droppedFrames == 1)
    let held = try #require(mailbox.take())
    #expect(held.timestampNs == 20 && held.sourceTimestampNs == 20)
    #expect(held.receivedAtSeconds != nil)

    renderer.renderFrame(try frame(identity: 30, rotation: ._0, timeStampNs: 30))
    renderer.stop()
    #expect(!mailbox.isHolding)
    // A stopped renderer releases its surface and never takes another frame.
    renderer.renderFrame(try frame(identity: 40, rotation: ._0, timeStampNs: 40))
    #expect(!mailbox.isHolding)
    #expect(metrics.snapshot().counters["receivedFrames"] == 3)
  }

  @Test func theOptionalPacingTrialIsIndependentOfPlayoutAndProvenanceIsNotPartOfCompatibility() {
    typealias Selection = ScreenSharingFieldTrials.Selection
    let paced = Selection.probeOptions(
      jitterWindowFrames: nil, lowLatencyPlayout: false, playoutDelayBoundsMs: nil, pacingFactor: 4)
    #expect(paced.trials == ["WebRTC-Video-Pacing": "factor:4.0"] && paced.name == "probe options")
    // Pacing alone touches no playout experiment, so the label stays absent.
    #expect(paced.playoutExperimentLabel == nil)
    let both = Selection.probeOptions(
      jitterWindowFrames: nil, lowLatencyPlayout: true, playoutDelayBoundsMs: nil, pacingFactor: 4)
    #expect(both.trials["WebRTC-Video-Pacing"] == "factor:4.0")
    #expect(both.playoutExperimentLabel == "WebRTC-ForcePlayoutDelay min_ms:0,max_ms:0")
    // Provenance is descriptive: the same native map under another name is
    // compatible, while the values themselves still compare by every field.
    let renamed = Selection(name: "renamed", trials: paced.trials)
    #expect(paced.installs(renamed) && renamed.installs(paced) && paced != renamed)
    #expect(!paced.installs(both))
  }
}

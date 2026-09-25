import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

/// What this build is allowed to negotiate. The factory advertises exactly the
/// one codec its adapters implement and refuses to construct an adapter for any
/// other payload, so a remote offer cannot select a codec with no VideoToolbox
/// path behind it.
struct ScreenSharingCodecFactoryTests {
  @Test(arguments: ScreenSharingVideoCodec.allCases)
  func theFactoryAdvertisesExactlyTheCodecItWasBuiltFor(codec: ScreenSharingVideoCodec) throws {
    let factory = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics(), codec: codec)
    let advertised = factory.supportedCodecs()
    #expect(advertised.count == 1)
    let info = try #require(advertised.first)
    #expect(info.name == codec.payloadName)
    #expect(info.parameters == codec.sdpParameters)
  }

  @Test func theAdvertisedParametersPinTheProfileTierAndLevel() {
    // 42e034: constrained baseline at level 5.2, which covers the 4K60 ceiling,
    // with asymmetric levels allowed so a smaller viewer can answer lower.
    #expect(
      ScreenSharingVideoCodec.h264.sdpParameters == [
        "profile-level-id": "42e034", "packetization-mode": "1", "level-asymmetry-allowed": "1",
      ])
    // HEVC level-id 153 is level 5.1 at the main tier. Both HEVC variants share
    // the H265 payload name, so profile-id is the only thing separating Main
    // from Main 4:4:4 in the answer.
    #expect(ScreenSharingVideoCodec.hevc.sdpParameters == ["profile-id": "1", "tier-flag": "0", "level-id": "153"])
    #expect(ScreenSharingVideoCodec.hevc444.sdpParameters == ["profile-id": "4", "tier-flag": "0", "level-id": "153"])
    #expect(ScreenSharingVideoCodec.hevc.payloadName == ScreenSharingVideoCodec.hevc444.payloadName)
  }

  @Test func anAdapterIsBuiltOnlyForTheAdvertisedPayloadName() throws {
    let factory = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics())
    let advertised = try #require(factory.supportedCodecs().first)
    #expect(factory.createEncoder(advertised) != nil)
    #expect(factory.createDecoder(advertised) != nil)
    // Names are matched exactly: a codec this build does not implement, and a
    // spelling WebRTC never sends, both fail to select an adapter.
    for name in ["H265", "VP8", "VP9", "AV1", "h264", "H264 ", ""] {
      #expect(factory.createEncoder(RTCVideoCodecInfo(name: name)) == nil)
      #expect(factory.createDecoder(RTCVideoCodecInfo(name: name)) == nil)
    }
  }

  @Test func anHEVCFactoryRefusesTheH264PayloadAndTheOtherWayAround() throws {
    let hevc = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics(), codec: .hevc)
    #expect(hevc.createEncoder(RTCVideoCodecInfo(name: "H264")) == nil)
    #expect(hevc.createDecoder(RTCVideoCodecInfo(name: "H264")) == nil)
    // Parameters do not participate in selection: the payload name alone picks
    // the adapter, and the negotiated profile rides in the SDP.
    let bareName = RTCVideoCodecInfo(name: "H265")
    #expect(hevc.createEncoder(bareName) != nil && hevc.createDecoder(bareName) != nil)
  }

  @Test(arguments: ScreenSharingVideoCodec.allCases)
  func theAdaptersNameTheirImplementationAndTheirAlignment(codec: ScreenSharingVideoCodec) throws {
    let factory = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics(), codec: codec)
    let info = try #require(factory.supportedCodecs().first)
    let encoder = try #require(factory.createEncoder(info))
    #expect(encoder.implementationName() == "CodevisorVideoToolbox\(codec.payloadName)")
    // Even dimensions for the hardware encoder, and the native CVPixelBuffer is
    // taken as is: cropping or scaling in WebRTC would break frame identity.
    #expect(encoder.resolutionAlignment == 2 && encoder.applyAlignmentToAllSimulcastLayers)
    #expect(encoder.supportsNativeHandle)
    // No QP thresholds: a screen share is never scaled down by WebRTC's
    // quality controller.
    #expect(encoder.scalingSettings() == nil)
    let decoder = try #require(factory.createDecoder(info))
    #expect(decoder.implementationName() == "CodevisorVideoToolbox\(codec.payloadName)")
  }

  @Test func eachAdapterIsANewInstanceOverSharedDiagnosticState() throws {
    let factory = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics())
    let info = try #require(factory.supportedCodecs().first)
    let first = try #require(factory.createEncoder(info))
    let second = try #require(factory.createEncoder(info))
    #expect(first !== second)
    // The injected faults are owned by the factory, so the probe can arm them
    // before WebRTC has built an adapter. Neither is armed in the app.
    #expect(!factory.encoderDropCheck.consume())
    #expect(factory.recoveryCheck.inspect(keyFrame: false, nowNs: 0) == .accept)
  }
}

/// 851-2372: HEVC preferred with an H.264 fallback, so a new app talks HEVC to a new app and
/// still connects to an older one that offers or answers H.264 only.
struct ScreenSharingCodecFallbackTests {
  @Test func fallbacksFollowThePrimaryInOrderWithoutRepeats() {
    #expect(ScreenSharingCodecFactory.negotiable(primary: .hevc, fallbacks: [.h264]) == [.hevc, .h264])
    #expect(ScreenSharingCodecFactory.negotiable(primary: .h264, fallbacks: [.h264]) == [.h264])
    // 851-2381: the host captures in the negotiated codec's format, so Main 4:4:4 (BGRA) can
    // fall back to Main and H.264 (NV12).
    #expect(
      ScreenSharingCodecFactory.negotiable(primary: .hevc444, fallbacks: [.hevc, .h264]) == [.hevc444, .hevc, .h264])
  }

  @Test func bothHEVCProfilesAreAdvertisedAndSelectedByProfileID() throws {
    let factory = ScreenSharingCodecFactory(
      metrics: ScreenSharingMetrics(), codec: .hevc444, fallbackCodecs: [.hevc, .h264])
    #expect(factory.supportedCodecs().map { $0.parameters["profile-id"] ?? $0.name } == ["4", "1", "H264"])
    #expect(factory.codec(for: RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "4"])) == .hevc444)
    #expect(factory.codec(for: RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "1"])) == .hevc)
    #expect(factory.codec(for: RTCVideoCodecInfo(name: "H265")) == .hevc, "no profile-id means Main")
    #expect(factory.codec(for: RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "2"])) == nil)
    let mainOnly = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics(), codec: .hevc)
    #expect(mainOnly.codec(for: RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "4"])) == nil)
  }

  @Test func theNegotiatedCodecIsReadFromADescription() {
    let sdp = [
      "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 98 96 100", "a=rtpmap:96 H264/90000", "a=rtpmap:98 H265/90000",
      "a=fmtp:98 level-id=153;profile-id=4;tier-flag=0", "a=rtpmap:100 H265/90000", "a=fmtp:100 profile-id=1",
    ].joined(separator: "\r\n")
    #expect(ScreenSharingVideoCodec.negotiated(inDescription: sdp) == .hevc444)
    #expect(
      ScreenSharingVideoCodec.negotiated(
        inDescription: sdp.replacingOccurrences(of: "SAVPF 98 96", with: "SAVPF 96 98"))
        == .h264)
    #expect(
      ScreenSharingVideoCodec.negotiated(
        inDescription: sdp.replacingOccurrences(of: "SAVPF 98 96 100", with: "SAVPF 100"))
        == .hevc)
    #expect(ScreenSharingVideoCodec.negotiated(inDescription: "v=0\r\nm=audio 9 RTP 0") == nil)
  }

  @Test func theFactoryAdvertisesItsCodecsInOrderAndBuildsAdaptersForEach() throws {
    let factory = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics(), codec: .hevc, fallbackCodecs: [.h264])
    #expect(factory.supportedCodecs().map(\.name) == ["H265", "H264"])
    for name in ["H265", "H264"] {
      #expect(factory.createEncoder(RTCVideoCodecInfo(name: name)) != nil)
      #expect(factory.createDecoder(RTCVideoCodecInfo(name: name)) != nil)
    }
    #expect(factory.createEncoder(RTCVideoCodecInfo(name: "VP8")) == nil)
    #expect(
      ScreenSharingPeerOptions().codec == .hevc444 && ScreenSharingPeerOptions().fallbackCodecs == [.hevc, .h264])
  }

  /// 851-2381: Main 4:4:4 can't use the low-latency encoder, so a peer that asked for it gets
  /// speed-prioritised standard rate control; every other combination is left as asked.
  @Test func fourFourFourTradesLowLatencyForTheEncodersSpeedPreference() {
    let map = ScreenSharingCodecFactory.rateControl
    #expect(map(.hevc444, true, false) == (false, true))
    #expect(map(.hevc444, false, false) == (false, false), "an explicit standard-rate experiment stays as it is")
    #expect(map(.hevc, true, false) == (true, false))
    #expect(map(.h264, false, true) == (false, true))
    let factory = ScreenSharingCodecFactory(metrics: ScreenSharingMetrics(), codec: .hevc444)
    #expect(factory.createEncoder(RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "4"])) != nil)
  }

  /// The codec an answerer picks for an offer, through real WebRTC negotiation (no network).
  static func negotiated(
    offerer: [ScreenSharingVideoCodec], answerer: [ScreenSharingVideoCodec]
  ) async throws -> ScreenSharingVideoCodec? {
    func connection(_ codecs: [ScreenSharingVideoCodec]) -> (RTCPeerConnectionFactory, RTCPeerConnection) {
      let codecFactory = ScreenSharingCodecFactory(
        metrics: ScreenSharingMetrics(), codec: codecs[0], fallbackCodecs: Array(codecs.dropFirst()))
      let factory = RTCPeerConnectionFactory(encoderFactory: codecFactory, decoderFactory: codecFactory)
      let configuration = RTCConfiguration()
      configuration.sdpSemantics = .unifiedPlan
      let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      return (factory, factory.peerConnection(with: configuration, constraints: constraints, delegate: nil)!)
    }
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let (offerFactory, offering) = connection(offerer)
    let (answerFactory, answering) = connection(answerer)
    defer {
      offering.close()
      answering.close()
      withExtendedLifetime((offerFactory, answerFactory)) {}
    }
    let transceiverInit = RTCRtpTransceiverInit()
    transceiverInit.direction = .recvOnly
    _ = offering.addTransceiver(of: .video, init: transceiverInit)
    let offer = try await offering.offer(for: constraints)
    try await answering.setRemoteDescription(offer)
    let answer = try await answering.answer(for: constraints)
    return ScreenSharingVideoCodec.negotiated(inDescription: answer.sdp)
  }

  @Test func newPeersNegotiateHEVCAndEitherOlderPeerFallsBackToH264() async throws {
    #expect(try await Self.negotiated(offerer: [.hevc, .h264], answerer: [.hevc, .h264]) == .hevc)
    #expect(try await Self.negotiated(offerer: [.h264], answerer: [.hevc, .h264]) == .h264)
    #expect(try await Self.negotiated(offerer: [.hevc, .h264], answerer: [.h264]) == .h264)
  }

  /// 851-2381: 4:4:4 between new peers; an older peer on either side gets HEVC Main, never a
  /// 4:4:4 stream it can't decode.
  @Test func newPeersNegotiateFourFourFourAndOlderPeersGetHEVCMain() async throws {
    let new: [ScreenSharingVideoCodec] = [.hevc444, .hevc, .h264]
    #expect(try await Self.negotiated(offerer: new, answerer: new) == .hevc444)
    #expect(try await Self.negotiated(offerer: [.hevc, .h264], answerer: new) == .hevc)
    #expect(try await Self.negotiated(offerer: new, answerer: [.hevc, .h264]) == .hevc)
    #expect(try await Self.negotiated(offerer: [.h264], answerer: new) == .h264)
  }
}

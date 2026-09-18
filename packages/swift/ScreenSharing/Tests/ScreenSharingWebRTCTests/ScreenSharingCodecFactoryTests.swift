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

import Testing
import VideoToolbox

@testable import ScreenSharingV2

@Suite struct ScreenSharingV2ChromaTests {
  @Test func aViewerThatCannotDecodeFourFourFourGetsTheVideoToolboxEncoder() {
    let vcp = [ScreenSharingV2EncoderKind.environmentKey: "vcp"]
    #expect(ScreenSharingV2EncoderKind.forViewer(chroma: "420", environment: vcp) == .videoToolbox)
    #expect(ScreenSharingV2EncoderKind.forViewer(chroma: "444", environment: vcp) == .videoProcessing)
    #expect(ScreenSharingV2EncoderKind.forViewer(chroma: nil, environment: vcp) == .videoProcessing)
  }
}

extension HardwareCodecTests {
  @Suite struct ScreenSharingV2ChromaProbeTests {
    @Test(
      .enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "No hardware HEVC decoder on this machine."))
    func theProbeDecodesItsFourFourFourKeyframeOnAMacThatDecodesFourFourFour() {
      #expect(ScreenSharingV2ChromaProbe.decodesFullChroma())
    }
  }
}

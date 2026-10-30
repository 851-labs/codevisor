import CoreMedia
import ScreenSharing
import Synchronization
import VideoToolbox

final class EncodeLabTileEncoder: @unchecked Sendable {
  private struct State {
    var outputs: [EncodeLabTileOutput] = []
    var acks = EncodeLabLTRAcks()
  }

  let tile: Int
  private let session: VTCompressionSession
  private let state = Mutex(State())

  init(tile: Int, session: VTCompressionSession) {
    self.tile = tile
    self.session = session
  }

  deinit {
    VTCompressionSessionInvalidate(session)
  }

  var outputs: [EncodeLabTileOutput] { state.withLock { $0.outputs.sorted { $0.frame < $1.frame } } }

  func encode(_ pixels: CVPixelBuffer, frame: Int, tick: Int, refresh: EncodeLabRefresh?) throws {
    let submitNs = ScreenSharingMetrics.nowNs
    let options = frameOptions(refresh: refresh, atNs: submitNs)
    let status = VTCompressionSessionEncodeFrame(
      session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: CMTimeValue(tick), timescale: 60),
      duration: .invalid, frameProperties: options as CFDictionary?, infoFlagsOut: nil
    ) { [self] status, _, sample in
      record(EncodeLabSampleInfo(frame: frame, submitNs: submitNs, refresh: refresh != nil, sample: sample))
    }
    guard status == noErr else { throw EncodeLabError.encoder("encode frame \(frame)", status) }
  }

  func finish() {
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
  }

  private func frameOptions(refresh: EncodeLabRefresh?, atNs: Int64) -> [CFString: Any]? {
    var options: [CFString: Any] = [:]
    let acknowledged = state.withLock { $0.acks.takeDue(atNs: atNs) }
    if !acknowledged.isEmpty { options[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acknowledged }
    switch refresh {
    case .keyframe: options[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
    case .longTermReference: options[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true
    case nil: break
    }
    return options.isEmpty ? nil : options
  }

  private func record(_ info: EncodeLabSampleInfo) {
    let outputNs = ScreenSharingMetrics.nowNs
    let output = info.output(tile: tile, outputNs: outputNs)
    state.withLock { state in
      state.outputs.append(output)
      if let token = info.longTermReferenceToken { state.acks.received(token: token, atNs: outputNs) }
    }
  }
}

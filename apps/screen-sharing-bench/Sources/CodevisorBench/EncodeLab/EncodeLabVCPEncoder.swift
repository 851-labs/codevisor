import CoreMedia
import ScreenSharing
import Synchronization
import VideoToolbox

final class EncodeLabVCPEncoder: EncodeLabFrameEncoder, @unchecked Sendable {
  private struct State {
    var outputs: [EncodeLabTileOutput] = []
    var acks: EncodeLabTokenAcks
    var submits: [Int: EncodeLabVCPSubmit] = [:]
  }

  private let api: EncodeLabVideoProcessing
  private let state: Mutex<State>
  private var session: AnyObject?

  init(config: EncodeLabConfig) throws {
    api = try EncodeLabVideoProcessing()
    state = Mutex(State(acks: EncodeLabTokenAcks(roundTripNs: config.ackRoundTripNs)))
    let session = try EncodeLabVCPSessionFactory(api: api, config: config).make(refcon: Unmanaged.passUnretained(self))
    self.session = session
  }

  deinit {
    if let session { api.invalidate(session) }
  }

  var outputs: [EncodeLabTileOutput] { state.withLock { $0.outputs } }

  func encode(_ inputs: [Int: CVPixelBuffer], frame: Int, tick: Int, refresh: EncodeLabRefresh?) throws {
    guard let session, let pixels = inputs[0] else { return }

    let submitNs = ScreenSharingMetrics.nowNs
    let options = frameOptions(
      refresh: refresh, submit: EncodeLabVCPSubmit(submitNs: submitNs, refresh: refresh != nil), frame: frame)
    let status = api.encode(
      session, pixels, CMTime(value: CMTimeValue(tick), timescale: 60), CMTime(value: 1, timescale: 60),
      options as CFDictionary?, UnsafeMutableRawPointer(bitPattern: frame + 1), nil)
    guard status == noErr else { throw EncodeLabError.encoder("encode frame \(frame)", status) }
  }

  func finish() {
    guard let session else { return }

    _ = api.complete(session, .invalid)
  }

  func record(frameRefcon: UnsafeMutableRawPointer?, sample: CMSampleBuffer?) {
    let outputNs = ScreenSharingMetrics.nowNs
    let frame = Int(bitPattern: frameRefcon) - 1
    let attachments = EncodeLabVCPAttachments(sample, tokenKey: api.requireTokenKey)
    state.withLock { state in
      guard let submit = state.submits[frame] else { return }

      let info = EncodeLabSampleInfo(frame: frame, submitNs: submit.submitNs, refresh: submit.refresh, sample: sample)
      state.outputs.append(info.output(tile: attachments.tile, outputNs: outputNs))
      if let token = attachments.token { state.acks.received(token: token, atNs: outputNs) }
    }
  }

  private func frameOptions(refresh: EncodeLabRefresh?, submit: EncodeLabVCPSubmit, frame: Int) -> [CFString: Any]? {
    var options: [CFString: Any] = [:]
    let acknowledged = state.withLock { state in
      state.submits[frame] = submit
      return state.acks.takeDue(atNs: submit.submitNs)
    }
    if !acknowledged.isEmpty { options[api.acknowledgedTokensKey] = acknowledged }
    switch refresh {
    case .keyframe: options[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
    case .longTermReference: options[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true
    case nil: break
    }
    return options.isEmpty ? nil : options
  }
}

struct ScreenSharingV2RecoveryGate {
  private var states: [UInt8: ScreenSharingV2DecodeState] = [:]

  func state(of stream: UInt8) -> ScreenSharingV2DecodeState {
    states[stream, default: .needsKeyframe]
  }

  mutating func admits(stream: UInt8, isKeyFrame: Bool, isRefresh: Bool) -> Bool {
    guard isDecodable(state(of: stream), isKeyFrame: isKeyFrame, isRefresh: isRefresh) else { return false }

    states[stream] = .decoding
    return true
  }

  mutating func broke(stream: UInt8) {
    guard state(of: stream) == .decoding else { return }

    states[stream] = .needsRefresh
  }

  private func isDecodable(_ state: ScreenSharingV2DecodeState, isKeyFrame: Bool, isRefresh: Bool) -> Bool {
    switch state {
    case .needsKeyframe: isKeyFrame
    case .needsRefresh: isKeyFrame || isRefresh
    case .decoding: true
    }
  }
}

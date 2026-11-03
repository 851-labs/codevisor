struct ScreenSharingV2RecoveryGate {
  struct Admission: Equatable, Sendable {
    let epoch: UInt64
    let recovers: Bool
  }

  private struct Stream {
    var state = ScreenSharingV2DecodeState.needsKeyframe
    var epoch: UInt64 = 0
    var brokenNs: Int64?
    var askedNs: Int64?
  }

  static let stallNs: Int64 = 100_000_000

  private var streams: [UInt8: Stream] = [:]

  func state(of stream: UInt8) -> ScreenSharingV2DecodeState {
    streams[stream]?.state ?? .needsKeyframe
  }

  mutating func admits(stream: UInt8, isKeyFrame: Bool, isRefresh: Bool) -> Admission? {
    var entry = streams[stream] ?? Stream()
    defer { streams[stream] = entry }
    guard Self.isDecodable(entry.state, isKeyFrame: isKeyFrame, isRefresh: isRefresh) else { return nil }

    if entry.state != .decoding {
      entry.epoch += 1
      entry.state = .decoding
    }
    return Admission(epoch: entry.epoch, recovers: isKeyFrame || isRefresh)
  }

  mutating func decoded(stream: UInt8, _ admission: Admission, atNs nowNs: Int64) -> Int64? {
    guard var entry = streams[stream], entry.state == .decoding, entry.epoch == admission.epoch,
      let brokenNs = entry.brokenNs
    else { return nil }

    entry.brokenNs = nil
    entry.askedNs = nil
    streams[stream] = entry
    return nowNs - brokenNs
  }

  mutating func failed(stream: UInt8, _ admission: Admission, atNs nowNs: Int64) -> ScreenSharingTileRefresh? {
    guard let entry = streams[stream], entry.state == .decoding, entry.epoch == admission.epoch else { return nil }

    return ask(admission.recovers ? .keyframe : .longTermReference, stream: stream, atNs: nowNs)
  }

  mutating func lostSession(stream: UInt8, atNs nowNs: Int64) -> ScreenSharingTileRefresh {
    ask(.keyframe, stream: stream, atNs: nowNs)
  }

  mutating func skipped(stream: UInt8, atNs nowNs: Int64) {
    guard var entry = streams[stream], entry.state == .decoding else { return }

    entry.state = .needsRefresh
    entry.brokenNs = nowNs
    streams[stream] = entry
  }

  mutating func rejected(stream: UInt8, atNs nowNs: Int64) -> ScreenSharingTileRefresh? {
    var entry = streams[stream] ?? Stream()
    defer { streams[stream] = entry }
    guard let brokenNs = entry.brokenNs else {
      entry.brokenNs = nowNs
      return nil
    }
    guard nowNs - (entry.askedNs ?? brokenNs) >= Self.stallNs else { return nil }

    entry.askedNs = nowNs
    return entry.state == .needsKeyframe ? .keyframe : .longTermReference
  }

  private mutating func ask(
    _ refresh: ScreenSharingTileRefresh, stream: UInt8, atNs nowNs: Int64
  ) -> ScreenSharingTileRefresh {
    var entry = streams[stream] ?? Stream()
    entry.state = refresh == .keyframe ? .needsKeyframe : .needsRefresh
    entry.brokenNs = entry.brokenNs ?? nowNs
    entry.askedNs = nowNs
    streams[stream] = entry
    return refresh
  }

  private static func isDecodable(_ state: ScreenSharingV2DecodeState, isKeyFrame: Bool, isRefresh: Bool) -> Bool {
    switch state {
    case .needsKeyframe: isKeyFrame
    case .needsRefresh: isKeyFrame || isRefresh
    case .decoding: true
    }
  }
}

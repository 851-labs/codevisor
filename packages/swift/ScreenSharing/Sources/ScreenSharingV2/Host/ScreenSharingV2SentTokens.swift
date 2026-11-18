struct ScreenSharingV2SentTokens: Sendable {
  private struct Entry: Sendable {
    let sent: UInt64
    let token: UInt64
  }

  static let remembered = 256
  private static let sequenceBits: UInt64 = 32

  private let generation: ScreenSharingV2EncoderGeneration
  private var sequence: UInt32 = 0
  private var entries: [Int: [Entry]] = [:]

  init(generation: ScreenSharingV2EncoderGeneration) {
    self.generation = generation
  }

  mutating func sending(_ token: UInt64, tile: Int) -> UInt64 {
    sequence &+= 1
    let sent = UInt64(generation.number) << Self.sequenceBits | UInt64(sequence)
    var remembered = entries[tile, default: []]
    remembered.append(Entry(sent: sent, token: token))
    if remembered.count > Self.remembered { remembered.removeFirst() }
    entries[tile] = remembered
    return sent
  }

  func token(acknowledgedAs sent: UInt64, tile: Int) -> UInt64? {
    entries[tile]?.last { $0.sent == sent }?.token
  }
}

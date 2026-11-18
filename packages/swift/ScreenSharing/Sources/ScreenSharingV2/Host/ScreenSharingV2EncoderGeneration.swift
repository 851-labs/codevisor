import Synchronization

public struct ScreenSharingV2EncoderGeneration: Equatable, Sendable {
  private static let started = Atomic<UInt32>(0)
  private static let tokenBits: UInt64 = 32

  public let number: UInt32

  public init(number: UInt32) {
    self.number = number
  }

  public static func next() -> ScreenSharingV2EncoderGeneration {
    ScreenSharingV2EncoderGeneration(number: started.add(1, ordering: .relaxed).newValue)
  }

  func replaces(_ other: ScreenSharingV2EncoderGeneration) -> Bool {
    Int32(bitPattern: number &- other.number) > 0
  }

  func sentToken(for token: UInt64) -> UInt64? {
    guard token >> Self.tokenBits == 0 else { return nil }

    return UInt64(number) << Self.tokenBits | token
  }

  func token(acknowledgedAs sent: UInt64) -> UInt64? {
    guard sent >> Self.tokenBits == UInt64(number) else { return nil }

    return sent & UInt64(UInt32.max)
  }
}

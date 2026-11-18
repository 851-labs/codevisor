import Synchronization

public struct ScreenSharingV2EncoderGeneration: Equatable, Sendable {
  private static let started = Atomic<UInt32>(0)

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
}

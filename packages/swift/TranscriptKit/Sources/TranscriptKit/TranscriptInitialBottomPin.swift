public struct TranscriptInitialBottomPin: Sendable, Equatable {
  public private(set) var isActive = false

  public init() {}

  public mutating func configure(restoresNonBottomPosition: Bool) {
    isActive = !restoresNonBottomPosition
  }

  public mutating func release() {
    isActive = false
  }
}

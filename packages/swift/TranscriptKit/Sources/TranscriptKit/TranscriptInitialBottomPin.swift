public struct TranscriptInitialBottomPin: Sendable, Equatable {
  public private(set) var isActive = false
  public private(set) var isConfigured = false

  public init() {}

  public mutating func configure(restoresNonBottomPosition: Bool) {
    guard !isConfigured else { return }
    isConfigured = true
    isActive = !restoresNonBottomPosition
  }

  public mutating func release() {
    isActive = false
  }
}

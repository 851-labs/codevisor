public struct ServerSessionStreamEnvelope: Equatable, Sendable {
  public var byteCount: Int = 1024
  public let cursor: Int
  public let event: ServerSessionStreamEvent

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.cursor == rhs.cursor && lhs.event == rhs.event }

  public init(cursor: Int, event: ServerSessionStreamEvent) {
    self.cursor = cursor
    self.event = event
  }
}

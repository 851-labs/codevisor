import CoreGraphics

public struct TranscriptPaginationHeaderLayout: Sendable, Equatable {
  public static let reservedHeight: CGFloat = 56

  public private(set) var reservesSpace = false

  public init() {}

  @discardableResult
  public mutating func reserveIfNeeded(
    hasOlderHistory: Bool,
    isPresented: Bool
  ) -> Bool {
    guard !reservesSpace, hasOlderHistory || isPresented else { return false }
    reservesSpace = true
    return true
  }

  public var height: CGFloat {
    reservesSpace ? Self.reservedHeight : 0
  }

  public func rowOrigin(topPadding: CGFloat, rowOffset: CGFloat) -> CGFloat {
    topPadding + height + rowOffset
  }

  public func documentHeight(topPadding: CGFloat, rowsHeight: CGFloat) -> CGFloat {
    max(1, topPadding + height + rowsHeight)
  }
}

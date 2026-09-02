import CoreGraphics

/// Stable leading geometry reserved for reverse-pagination feedback.
///
/// The reservation is intentionally sticky for the lifetime of a transcript
/// surface. Showing or hiding the progress indicator therefore never changes
/// document size while UIKit/AppKit is tracking native scroll momentum.
public struct TranscriptPaginationHeaderLayout: Sendable, Equatable {
  /// Leaves comfortable vertical breathing room around the native spinner.
  /// A medium iOS indicator is 20 points tall, so this provides 18 points
  /// above and below it while keeping the reservation stable during paging.
  public static let reservedHeight: CGFloat = 56

  public private(set) var reservesSpace = false

  public init() {}

  /// Reserves the header as soon as this transcript can paginate. Once
  /// reserved, the space remains stable until the native transcript is
  /// dismantled—even after the final page proves there is no more history.
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

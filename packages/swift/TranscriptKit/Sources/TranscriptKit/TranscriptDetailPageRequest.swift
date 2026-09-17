import CoreGraphics
import Foundation

public struct TranscriptDetailPageRequest: Equatable, Hashable, Sendable {
  public let itemID: String
  public let cursor: String
  public let previous: Bool

  public init(itemID: String, cursor: String, previous: Bool) {
    self.itemID = itemID
    self.cursor = cursor
    self.previous = previous
  }
}

/// Only user scrolling changes direction. Installing a detail page cannot
/// immediately request the page evicted from the opposite end of the window.
public struct TranscriptDetailPrefetchPolicy: Sendable {
  private var previous: Bool?
  private var lastAccepted: TranscriptDetailPageRequest?
  private var scrollRevision: UInt64 = 0
  private var acceptedScrollRevision: UInt64?

  public init() {}

  public mutating func observeUserScroll(delta: CGFloat) {
    if abs(delta) > 0.5 {
      previous = delta < 0
      scrollRevision &+= 1
    }
  }

  public mutating func requestIfNeeded(
    _ page: TranscriptDetailPageRequest,
    distance: CGFloat,
    threshold: CGFloat,
    request: () -> Bool
  ) -> Bool {
    if abs(distance) > threshold * 1.25, lastAccepted == page { lastAccepted = nil }
    guard previous == page.previous, abs(distance) <= threshold,
      acceptedScrollRevision != scrollRevision,
      page != lastAccepted, request()
    else { return false }
    lastAccepted = page
    acceptedScrollRevision = scrollRevision
    return true
  }
}

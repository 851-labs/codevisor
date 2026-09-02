/// Keeps a fresh or previously bottom-aligned transcript attached to its
/// bottom edge until the initial presentation snapshot is complete.
///
/// Initial row estimates are replaced asynchronously by parsed Markdown,
/// attachment, and native text measurements. Treating those corrections like
/// ordinary settled-content changes preserves a visible row and can leave the
/// first visible frame above the bottom. A genuine non-bottom restoration does
/// not acquire this pin because its saved block anchor remains authoritative.
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

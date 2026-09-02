import CoreGraphics
import Foundation

/// The virtualizer's in-memory height book, with one invariant: a height that
/// was actually measured is never discarded in favor of a flat estimate. When
/// a row's content changes (its measurement revision moves), the old height
/// stays in place as *stale* layout geometry and the next report for that key
/// must commit — even if the reported height is unchanged — so revision-keyed
/// caches relearn the row. Dropping the height instead is what made settled
/// rows snap to their estimates (and overlap their neighbors) whenever a
/// background subagent kept streaming into an already-settled turn.
public struct TranscriptMeasurementLedger: Sendable {
  /// Heights used for layout, exposed for `VirtualTranscriptLayout`.
  public private(set) var heightsByKey: [String: CGFloat]
  /// Keys whose height is provisional: still correct enough to position
  /// rows, but the next measurement report must commit unconditionally.
  private var staleKeys: Set<String>

  public init() {
    heightsByKey = [:]
    staleKeys = []
  }

  public subscript(key: String) -> CGFloat? {
    heightsByKey[key]
  }

  /// An authoritative height that needs no re-report (content-defined rows
  /// such as spacers, or cache entries whose revision was just verified).
  public mutating func setExact(_ height: CGFloat, for key: String) {
    heightsByKey[key] = height
    staleKeys.remove(key)
  }

  /// A height carried across a content or width change: used for layout so
  /// rows never collapse to estimates, but flagged so the next measurement
  /// commits even when it lands on the same value.
  public mutating func setProvisional(_ height: CGFloat, for key: String) {
    heightsByKey[key] = height
    staleKeys.insert(key)
  }

  /// The row's content changed under an existing measurement. Keep the last
  /// height for layout and require a fresh commit.
  public mutating func markStale(_ key: String) {
    guard heightsByKey[key] != nil else { return }
    staleKeys.insert(key)
  }

  public func isStale(_ key: String) -> Bool {
    staleKeys.contains(key)
  }

  /// Whether a reported height must be committed. Unchanged heights are
  /// deduped only for keys that are current; a stale key always commits so
  /// its revision-keyed cache entries can be rewritten.
  public func needsCommit(_ height: CGFloat, for key: String) -> Bool {
    staleKeys.contains(key) || abs((heightsByKey[key] ?? 0) - height) > 0.5
  }

  /// Commits a measured height and clears staleness. Returns whether the
  /// height actually moved (i.e. whether document geometry must rebuild).
  @discardableResult
  public mutating func commit(_ height: CGFloat, for key: String) -> Bool {
    let changed = abs((heightsByKey[key] ?? 0) - height) > 0.5
    heightsByKey[key] = height
    staleKeys.remove(key)
    return changed
  }

  public mutating func removeAll(keepingCapacity: Bool) {
    heightsByKey.removeAll(keepingCapacity: keepingCapacity)
    staleKeys.removeAll(keepingCapacity: keepingCapacity)
  }
}

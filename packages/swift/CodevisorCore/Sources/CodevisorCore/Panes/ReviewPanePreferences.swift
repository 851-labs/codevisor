import CodevisorClient
import Foundation

/// What a Review pane compares, shared through the pane registry so every
/// device showing the pane shows the same diff.
public struct ReviewPanePreferences: Codable, Equatable, Sendable {
  public var mode: ServerGitDiffMode
  /// Branch mode only: the ref to compare against. Nil follows the
  /// project's base branch.
  public var base: String?
  /// Files marked viewed: path → the fingerprint of the change that was
  /// viewed. A mark only counts while the file's current change has the
  /// same fingerprint, so any newer edit makes the file unviewed again.
  public var viewed: [String: String]

  public init(mode: ServerGitDiffMode = .branch, base: String? = nil, viewed: [String: String] = [:]) {
    self.mode = mode
    self.base = base
    self.viewed = viewed
  }

  /// Whether this exact change of the file was marked viewed. Nil
  /// fingerprints (servers that predate them) can't be tracked.
  public func isViewed(path: String, fingerprint: String?) -> Bool {
    guard let fingerprint else { return false }
    return viewed[path] == fingerprint
  }

  /// Marks or clears a file's viewed state. Marks for files outside
  /// `current` are dropped: they belong to changes no longer under review,
  /// and keeping them would grow the synced pane record without bound.
  public mutating func setViewed(
    _ isViewed: Bool, path: String, fingerprint: String?, current: Set<String>
  ) {
    viewed = viewed.filter { current.contains($0.key) }
    if isViewed, let fingerprint {
      viewed[path] = fingerprint
    } else {
      viewed[path] = nil
    }
  }

  /// Whether two preferences compare the same thing (viewed marks aside).
  public func comparesSame(as other: ReviewPanePreferences) -> Bool {
    mode == other.mode && base == other.base
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A mode added by a newer build falls back to the default rather
    // than dropping the whole pane.
    let rawMode = try container.decodeIfPresent(String.self, forKey: .mode)
    mode = rawMode.flatMap(ServerGitDiffMode.init(rawValue:)) ?? .branch
    base = try container.decodeIfPresent(String.self, forKey: .base)
    // Panes published before viewed marks existed have none.
    viewed = try container.decodeIfPresent([String: String].self, forKey: .viewed) ?? [:]
  }
}

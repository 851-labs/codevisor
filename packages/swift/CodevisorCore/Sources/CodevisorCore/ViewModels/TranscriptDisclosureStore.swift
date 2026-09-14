import Foundation
import Observation

/// Per-group observable state retained under the stable first-call id.
/// Activity never changes disclosure; the user's choice survives updates,
/// lazy transcript remounts, and navigation.
@MainActor
@Observable
public final class ToolGroupDisclosure {
  public private(set) var isExpanded = false

  public func userToggled() {
    isExpanded.toggle()
  }
}

/// Session-scoped store for user-toggled disclosure state (expand/collapse) of
/// transcript rows.
///
/// Lazy transcript rows unmount outside the viewport, so per-row `@State`
/// would forget a user's choice. Hoisting the toggle here under a stable id
/// preserves it across unmounts and navigation.
///
/// Ordinary disclosures use the Boolean map below. Tool groups use retained
/// per-key observable objects to keep each toggle scoped to one group row.
@MainActor
@Observable
public final class TranscriptDisclosureStore {
  /// A stable identity for a collapsible transcript region.
  public enum Key: Hashable, Sendable {
    /// An assistant turn's "Worked for…" section, keyed by the message id.
    case turn(UUID)
    /// The second "Worked for…" section — the work that follows an approved
    /// plan — keyed by the message id so it collapses independently of the
    /// planning section above the plan card.
    case turnImplementation(UUID)
    /// A single tool call's output card, keyed by tool-call id.
    case toolCall(String)
    /// A subagent thread, keyed by the Task tool-call id.
    case subagent(String)
  }

  private var values: [Key: Bool] = [:]
  /// Changes only when a transcript-level disclosure changes. Row-list
  /// presentation caches use this to avoid rescanning settled history on
  /// every active token flush.
  public private(set) var workedSectionRevision: UInt64 = 0
  @ObservationIgnored private var toolGroupDisclosures: [String: ToolGroupDisclosure] = [:]
  public init() {}

  /// Shared throwaway store for previews / detached contexts where no
  /// session-scoped store is injected. Not for production paths.
  public static let previews = TranscriptDisclosureStore()

  /// The stored value, or `defaultValue` when the user hasn't toggled it.
  /// The default carries the seeding logic each row used to compute in
  /// `init` (settled turns start collapsed, a running subagent starts open,
  /// etc.), so first render matches the old behavior exactly.
  public func isExpanded(_ key: Key, default defaultValue: Bool) -> Bool {
    values[key] ?? defaultValue
  }

  public func setExpanded(_ key: Key, _ expanded: Bool) {
    guard values[key] != expanded else { return }
    values[key] = expanded
    advanceWorkedSectionRevisionIfNeeded(for: key)
  }

  /// Toggles from the effective current value (stored ?? default).
  public func toggle(_ key: Key, default defaultValue: Bool) {
    values[key] = !(values[key] ?? defaultValue)
    advanceWorkedSectionRevisionIfNeeded(for: key)
  }

  public func toolGroupDisclosure(id: String) -> ToolGroupDisclosure {
    if let disclosure = toolGroupDisclosures[id] {
      return disclosure
    }
    let disclosure = ToolGroupDisclosure()
    toolGroupDisclosures[id] = disclosure
    return disclosure
  }

  private func advanceWorkedSectionRevisionIfNeeded(for key: Key) {
    switch key {
    case .turn, .turnImplementation:
      workedSectionRevision &+= 1
    case .toolCall, .subagent:
      break
    }
  }

}

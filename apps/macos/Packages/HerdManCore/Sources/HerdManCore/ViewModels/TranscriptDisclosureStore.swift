import Foundation
import Observation

/// Session-scoped store for user-toggled disclosure state (expand/collapse) of
/// transcript rows.
///
/// Why this exists: the transcript occlusion-culls settled rows — a row far
/// from the viewport unmounts its content and renders as a fixed-height
/// spacer. Per-row `@State` (the old home of `isExpanded`) is destroyed on
/// unmount, so a settled tool card the user manually expanded would silently
/// re-collapse when scrolled away and back. Hoisting the toggle here, keyed by
/// a STABLE id, makes it survive content unmount/remount.
///
/// Only the user-set toggle lives here. The transient auto-collapse/auto-expand
/// *guards* stay as per-row `@State`: those transitions fire only while a turn
/// is generating, and the generating turn is the active row, which is never
/// culled — so by the time a row can be culled its disclosure only ever changes
/// by user tap, which requires the row to be mounted.
///
/// Observation granularity: a tap invalidates every mounted row that read the
/// store (`O(visible)`), which is fine — taps are rare and human-paced. Reads
/// during streaming register dependencies but the store isn't written then, so
/// streaming causes no invalidation here.
@MainActor
@Observable
public final class TranscriptDisclosureStore {
    /// A stable identity for a collapsible transcript region.
    public enum Key: Hashable, Sendable {
        /// An assistant turn's "Worked for…" section, keyed by the message id.
        case turn(UUID)
        /// A collapsed tool-call group, keyed by its first call's id (groups
        /// only append, so the first id is stable).
        case toolGroup(String)
        /// A single tool call's output card, keyed by tool-call id.
        case toolCall(String)
        /// A subagent thread, keyed by the Task tool-call id.
        case subagent(String)
    }

    private var values: [Key: Bool] = [:]

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
        values[key] = expanded
    }

    /// Toggles from the effective current value (stored ?? default).
    public func toggle(_ key: Key, default defaultValue: Bool) {
        values[key] = !(values[key] ?? defaultValue)
    }
}

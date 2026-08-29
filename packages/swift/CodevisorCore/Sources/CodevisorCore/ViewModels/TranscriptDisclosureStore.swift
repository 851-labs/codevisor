import Foundation
import Observation

public enum ToolGroupAutomaticDisclosurePolicy: Sendable, Equatable {
    /// Top-level groups stay open while they are the latest work and close
    /// when the model moves on, unless the user explicitly changed them.
    case followLatestWork
    /// Nested groups opened by live work remain open after that work settles.
    case remainExpandedAfterActivity
}

public struct ToolGroupDisclosureContext: Sendable, Equatable {
    public let hasUnsettledCall: Bool
    public let followsLatestWork: Bool

    public init(hasUnsettledCall: Bool, followsLatestWork: Bool) {
        self.hasUnsettledCall = hasUnsettledCall
        self.followsLatestWork = followsLatestWork
    }
}

public enum ToolGroupDisclosureState: Sendable, Equatable {
    case collapsed
    case expanded
    case followingLatestWork
    case forcedExpanded

    public var isExpanded: Bool { self != .collapsed }
}

enum ToolGroupDisclosureReducer {
    static func initialState(
        policy: ToolGroupAutomaticDisclosurePolicy,
        context: ToolGroupDisclosureContext
    ) -> ToolGroupDisclosureState {
        if context.hasUnsettledCall { return .forcedExpanded }
        if policy == .followLatestWork, context.followsLatestWork {
            return .followingLatestWork
        }
        return .collapsed
    }

    static func contextChanged(
        state: ToolGroupDisclosureState,
        policy: ToolGroupAutomaticDisclosurePolicy,
        previous: ToolGroupDisclosureContext,
        current: ToolGroupDisclosureContext
    ) -> ToolGroupDisclosureState {
        if current.hasUnsettledCall {
            return previous.hasUnsettledCall ? state : .forcedExpanded
        }

        if previous.hasUnsettledCall {
            switch policy {
            case .remainExpandedAfterActivity:
                return .expanded
            case .followLatestWork:
                return current.followsLatestWork ? .followingLatestWork : .collapsed
            }
        }

        guard policy == .followLatestWork else { return state }
        switch (previous.followsLatestWork, current.followsLatestWork, state) {
        case (false, true, .collapsed):
            return .followingLatestWork
        case (true, false, .followingLatestWork):
            return .collapsed
        default:
            return state
        }
    }

    static func userToggled(
        state: ToolGroupDisclosureState,
        context: ToolGroupDisclosureContext
    ) -> ToolGroupDisclosureState {
        guard !context.hasUnsettledCall else { return state }
        switch state {
        case .collapsed:
            return .expanded
        case .expanded, .followingLatestWork:
            return .collapsed
        case .forcedExpanded:
            // Defensive: the context is authoritative, but a forced state
            // should never become user-collapsible before reconciliation.
            return .forcedExpanded
        }
    }
}

/// Per-group observable state. It is retained by the session store under the
/// group's stable first-call id, so lazy transcript remounts preserve it while
/// changes invalidate only the affected group row.
@MainActor
@Observable
public final class ToolGroupDisclosure {
    /// Only the rendered Boolean is observed. Transitions between two visible
    /// states (for example forced -> ordinary expansion when a tool settles)
    /// therefore do not invalidate the row or trigger layout work.
    public private(set) var isExpanded: Bool
    @ObservationIgnored public private(set) var state: ToolGroupDisclosureState
    public var isUserToggleEnabled: Bool { !context.hasUnsettledCall }

    public let policy: ToolGroupAutomaticDisclosurePolicy
    @ObservationIgnored private var context: ToolGroupDisclosureContext

    init(policy: ToolGroupAutomaticDisclosurePolicy, context: ToolGroupDisclosureContext) {
        self.policy = policy
        self.context = context
        state = ToolGroupDisclosureReducer.initialState(policy: policy, context: context)
        isExpanded = state.isExpanded
    }

    public func reconcile(_ newContext: ToolGroupDisclosureContext) {
        guard newContext != context else { return }
        let newState = ToolGroupDisclosureReducer.contextChanged(
            state: state,
            policy: policy,
            previous: context,
            current: newContext
        )
        context = newContext
        setState(newState)
    }

    public func userToggled() {
        setState(ToolGroupDisclosureReducer.userToggled(state: state, context: context))
    }

    private func setState(_ newState: ToolGroupDisclosureState) {
        guard newState != state else { return }
        state = newState
        let expanded = newState.isExpanded
        guard expanded != isExpanded else { return }
        isExpanded = expanded
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
/// per-key observable objects because their automatic lifecycle transitions
/// are frequent during streaming; that keeps each update scoped to one row.
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
    }

    /// Toggles from the effective current value (stored ?? default).
    public func toggle(_ key: Key, default defaultValue: Bool) {
        values[key] = !(values[key] ?? defaultValue)
    }

    public func toolGroupDisclosure(
        id: String,
        policy: ToolGroupAutomaticDisclosurePolicy,
        initialContext: ToolGroupDisclosureContext
    ) -> ToolGroupDisclosure {
        if let disclosure = toolGroupDisclosures[id] {
            assert(disclosure.policy == policy, "A tool group must use one automatic disclosure policy")
            return disclosure
        }
        let disclosure = ToolGroupDisclosure(policy: policy, context: initialContext)
        toolGroupDisclosures[id] = disclosure
        return disclosure
    }

}

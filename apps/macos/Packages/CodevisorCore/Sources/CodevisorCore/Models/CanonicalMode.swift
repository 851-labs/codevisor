import ACPKit

/// Codevisor's harness-independent mode vocabulary. Providers map their native
/// permission/approval modes onto these ids so every harness renders the same
/// picker; modes without a mapping stay native-only.
public enum CanonicalMode: String, Sendable, CaseIterable {
    case readOnly
    case ask
    case autoEdit
    case fullAccess
    case plan

    /// Fixed display label — consistent across harnesses regardless of the
    /// native mode's own name.
    public var displayName: String {
        switch self {
        case .readOnly: "Read-only"
        case .ask: "Ask"
        case .autoEdit: "Auto edit"
        case .fullAccess: "Full access"
        case .plan: "Plan"
        }
    }

    public var symbolName: String {
        switch self {
        case .readOnly: "eye"
        case .ask: "questionmark.bubble"
        case .autoEdit: "pencil"
        case .fullAccess: "bolt"
        case .plan: "list.bullet.clipboard"
        }
    }
}

public extension SessionMode {
    var canonicalMode: CanonicalMode? {
        canonicalId.flatMap(CanonicalMode.init(rawValue:))
    }

    /// The canonical label when mapped, the agent's own name otherwise.
    var displayName: String {
        canonicalMode?.displayName ?? name
    }
}

public extension SessionModeState {
    /// Modes mapped onto the canonical vocabulary, in the fixed canonical
    /// order (readOnly, ask, autoEdit, fullAccess, plan).
    var canonicalModes: [SessionMode] {
        CanonicalMode.allCases.compactMap { canonical in
            availableModes.first { $0.canonicalMode == canonical }
        }
    }

    /// Agent-defined modes with no canonical mapping, rendered under an
    /// "Agent modes" divider so they stay reachable without polluting the
    /// canonical set.
    var nativeOnlyModes: [SessionMode] {
        availableModes.filter { $0.canonicalMode == nil }
    }

    var currentMode: SessionMode? {
        availableModes.first { $0.id == currentModeId }
    }
}

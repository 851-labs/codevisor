import Foundation

/// A session's scratchpad: free-form rich-text notes plus whether the
/// inspector pane is open. `text` round-trips through `AttributedString`'s
/// Codable conformance, which preserves attributes in the known scopes
/// (SwiftUI/Foundation — bold, italic, underline, strikethrough); bullets
/// are literal characters so they need no attribute support.
public struct ScratchpadState: Codable, Sendable, Equatable {
    /// Format version for forward migration if the encoding ever changes.
    public var version: Int
    public var text: AttributedString
    /// Whether the inspector is open for this session. Per-session (not
    /// app-global) so switching chats restores each one's own pane state.
    public var isVisible: Bool

    public init(version: Int = 1, text: AttributedString = AttributedString(), isVisible: Bool = false) {
        self.version = version
        self.text = text
        self.isVisible = isVisible
    }
}

/// Persists and retrieves each session's scratchpad.
public protocol ScratchpadRepository: Sendable {
    func load(sessionId: UUID) -> ScratchpadState?
    func save(_ state: ScratchpadState, sessionId: UUID)
}

/// File/in-memory backed scratchpad repository. Unlike
/// `DefaultPaneGroupRepository` (one tiny map under a single key), each
/// session's scratchpad lives under its own `scratchpad.<uuid>` key: rich-text
/// documents can grow, and packing them into one file would re-encode every
/// session's notes on each debounced keystroke save. No cache is needed —
/// the live `ScratchpadModel` holds the state and only loads once.
///
/// Scratchpads of deleted sessions are not removed (`PersistenceStore` has no
/// delete API); the orphaned files are small JSON documents.
public final class DefaultScratchpadRepository: ScratchpadRepository {
    private let store: any PersistenceStore

    public init(store: any PersistenceStore) {
        self.store = store
    }

    public func load(sessionId: UUID) -> ScratchpadState? {
        guard let data = store.loadData(forKey: key(sessionId)) else { return nil }
        return try? JSONDecoder().decode(ScratchpadState.self, from: data)
    }

    public func save(_ state: ScratchpadState, sessionId: UUID) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? store.saveData(data, forKey: key(sessionId))
    }

    private func key(_ sessionId: UUID) -> String {
        "scratchpad.\(sessionId.uuidString)"
    }
}

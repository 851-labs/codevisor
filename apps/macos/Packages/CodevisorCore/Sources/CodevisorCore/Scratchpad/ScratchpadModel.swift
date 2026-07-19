import Foundation
import Observation
import os

/// Per-session scratchpad state: the note text bound to the inspector's
/// editor plus the pane's open/closed state. Seeded from the repository on
/// creation; text edits persist through a short debounce (typing is
/// per-keystroke and JSON-encoding rich text on every character is the cost
/// being avoided — `FileSystemStore` already coalesces the disk writes
/// themselves off-main). Visibility changes persist immediately.
@MainActor
@Observable
public final class ScratchpadModel {
    /// Debounce for text-edit saves. Short enough that the window lost to a
    /// hard quit mid-debounce is negligible; `flush()` covers orderly paths.
    private static let saveDebounce: Duration = .milliseconds(500)

    public let sessionId: UUID
    /// Diagnostics for note persistence (seed/edit/save transitions with
    /// character counts only — never note content). Debug level: visible via
    /// `log stream --predicate 'subsystem == "com.851labs.codevisor"'` when
    /// chasing persistence issues, free otherwise.
    private static let log = Log.scratchpad

    public var text: AttributedString {
        didSet {
            guard text != oldValue else { return }
            Self.log.debug("text didSet \(self.sessionId): \(oldValue.characters.count) -> \(self.text.characters.count) chars")
            guard !isApplyingRemote else { return }
            updatedAt = Date()
            scheduleSave()
        }
    }

    /// True while `applyRemote` writes the text, so the edit observer
    /// neither re-stamps nor re-uploads what just came from the server.
    @ObservationIgnored private var isApplyingRemote = false
    public private(set) var isVisible: Bool
    /// The text's last local edit time (LWW stamp for server sync).
    public private(set) var updatedAt: Date?

    /// Fired after every persisted TEXT save with the state to mirror to
    /// the server (wired by the store; nil = no sync). Runs on the same
    /// debounce as disk saves — never per keystroke.
    @ObservationIgnored public var onContentSaved: ((ScratchpadState) -> Void)?

    @ObservationIgnored private let repository: any ScratchpadRepository
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// `legacyId` supports re-keying: when no record exists under
    /// `sessionId` (now typically a WORKSPACE id — the inspector belongs to
    /// the workspace, not one chat), the legacy per-chat record seeds the
    /// model and is re-persisted under the new key, so notes written before
    /// workspace scoping survive.
    public init(
        sessionId: UUID,
        legacyId: UUID? = nil,
        repository: any ScratchpadRepository
    ) {
        self.sessionId = sessionId
        self.repository = repository
        let loaded = repository.load(sessionId: sessionId)
        let adopted = loaded ?? legacyId.flatMap { repository.load(sessionId: $0) }
        let state = adopted ?? ScratchpadState()
        self.text = state.text
        self.isVisible = state.isVisible
        self.updatedAt = state.updatedAt
        if loaded == nil, adopted != nil {
            repository.save(state, sessionId: sessionId)
        }
        Self.log.debug("seed \(sessionId): loaded=\(adopted != nil) chars=\(state.text.characters.count) visible=\(state.isVisible)")
    }

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        // Visibility is DEVICE state — it never uploads on its own. But a
        // toggle can land inside a text edit's debounce window, and this
        // persist settles that pending edit too, so it must still sync.
        persistNow(syncsContent: pendingSave != nil)
    }

    public func toggle() {
        setVisible(!isVisible)
    }

    /// Persists any pending debounced edit immediately. Called when the
    /// inspector disappears and when the session's cached model is discarded.
    public func flush() {
        guard pendingSave != nil else { return }
        persistNow()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow(syncsContent: Bool = true) {
        pendingSave?.cancel()
        pendingSave = nil
        Self.log.debug("save \(self.sessionId): chars=\(self.text.characters.count) visible=\(self.isVisible)")
        let state = ScratchpadState(text: text, isVisible: isVisible, updatedAt: updatedAt)
        repository.save(state, sessionId: sessionId)
        if syncsContent { onContentSaved?(state) }
    }

    /// Applies the server's copy when it is NEWER than the local edit (LWW;
    /// equal stamps are a no-op). Persisted locally without re-uploading.
    public func applyRemote(text remoteText: AttributedString, updatedAt remoteStamp: Date) {
        if let updatedAt, remoteStamp <= updatedAt { return }
        guard remoteText != text || updatedAt == nil else {
            // Same content, newer stamp: adopt the stamp quietly.
            updatedAt = remoteStamp
            return
        }
        isApplyingRemote = true
        text = remoteText
        isApplyingRemote = false
        updatedAt = remoteStamp
        persistNow(syncsContent: false)
    }
}

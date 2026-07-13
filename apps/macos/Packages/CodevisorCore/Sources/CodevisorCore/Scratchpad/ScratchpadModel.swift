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
            scheduleSave()
        }
    }
    public private(set) var isVisible: Bool

    @ObservationIgnored private let repository: any ScratchpadRepository
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    public init(sessionId: UUID, repository: any ScratchpadRepository) {
        self.sessionId = sessionId
        self.repository = repository
        let loaded = repository.load(sessionId: sessionId)
        let state = loaded ?? ScratchpadState()
        self.text = state.text
        self.isVisible = state.isVisible
        Self.log.debug("seed \(sessionId): loaded=\(loaded != nil) chars=\(state.text.characters.count) visible=\(state.isVisible)")
    }

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        persistNow()
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

    private func persistNow() {
        pendingSave?.cancel()
        pendingSave = nil
        Self.log.debug("save \(self.sessionId): chars=\(self.text.characters.count) visible=\(self.isVisible)")
        repository.save(ScratchpadState(text: text, isVisible: isVisible), sessionId: sessionId)
    }
}

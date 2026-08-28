import Foundation

/// Persists the complete unsent new-chat composer per machine. Attachment
/// bytes use separate store keys so editing text never rewrites large blobs.
@MainActor
public final class ComposerDraftStore {
    public struct DraftAttachment: Equatable {
        public var id: UUID
        public var name: String
        public var mimeType: String
        public var kind: String
        public var localData: Data

        public init(id: UUID, name: String, mimeType: String, kind: String, localData: Data) {
            self.id = id
            self.name = name
            self.mimeType = mimeType
            self.kind = kind
            self.localData = localData
        }
    }

    public struct Draft: Equatable {
        public var projectId: UUID
        /// The project's machine. Optional because older persisted drafts
        /// predate cross-machine drafts; nil means "the machine whose slot
        /// this draft was saved under".
        public var projectServerId: String?
        public var composerText: String
        public var attachments: [DraftAttachment]
        public var selectedHarnessId: String?
        public var configByHarness: [String: [String: String]]
        public var modeId: String?
        public var isGoalComposerArmed: Bool
        public var isGoalEditing: Bool
        public var composerTextBeforeGoalEdit: String?

        public init(
            projectId: UUID,
            projectServerId: String? = nil,
            composerText: String = "",
            attachments: [DraftAttachment] = [],
            selectedHarnessId: String? = nil,
            configByHarness: [String: [String: String]] = [:],
            modeId: String? = nil,
            isGoalComposerArmed: Bool = false,
            isGoalEditing: Bool = false,
            composerTextBeforeGoalEdit: String? = nil
        ) {
            self.projectId = projectId
            self.projectServerId = projectServerId
            self.composerText = composerText
            self.attachments = attachments
            self.selectedHarnessId = selectedHarnessId
            self.configByHarness = configByHarness
            self.modeId = modeId
            self.isGoalComposerArmed = isGoalComposerArmed
            self.isGoalEditing = isGoalEditing
            self.composerTextBeforeGoalEdit = composerTextBeforeGoalEdit
        }
    }

    private struct PersistedAttachment: Codable, Sendable {
        var id: UUID
        var name: String
        var mimeType: String
        var kind: String
    }

    private struct PersistedDraft: Codable, Sendable {
        var projectId: UUID
        var projectServerId: String?
        var composerText: String
        var attachments: [PersistedAttachment]
        var selectedHarnessId: String?
        var configByHarness: [String: [String: String]]
        var modeId: String?
        var isGoalComposerArmed: Bool
        var isGoalEditing: Bool
        var composerTextBeforeGoalEdit: String?
    }

    private struct PersistedDrafts: Codable, Sendable {
        var machines: [String: PersistedDraft]
    }

    private struct PersistedPaneDrafts: Codable, Sendable {
        var panes: [String: PersistedDraft]
    }

    private let store: any PersistenceStore
    private let key: String
    private let paneKey: String
    private let persistenceOwner = UUID()
    private var drafts: [String: Draft] = [:]
    /// In-workspace draft chat panes, keyed by pane id. Same schema as the
    /// per-machine draft — an unsent in-workspace composer must survive
    /// relaunches and app updates just like the page draft does.
    private var paneDrafts: [UUID: Draft] = [:]

    public init(
        store: any PersistenceStore,
        key: String = "composer-drafts",
        paneKey: String = "composer-pane-drafts"
    ) {
        // Flush a previous instance's coalesced snapshot before replacing an
        // environment or reopening the store in tests.
        PersistenceEncoding.drain()
        self.store = store
        self.key = key
        self.paneKey = paneKey
        if let data = store.loadData(forKey: key) {
            do {
                let persisted = try JSONDecoder().decode(PersistedDrafts.self, from: data)
                drafts = persisted.machines.mapValues { Self.draft(from: $0, store: store) }
            } catch {
                handleCorruptPayload(store: store, key: key, data: data, error: error)
            }
        }
        if let data = store.loadData(forKey: paneKey) {
            do {
                let persisted = try JSONDecoder().decode(PersistedPaneDrafts.self, from: data)
                for (paneId, draft) in persisted.panes {
                    guard let id = UUID(uuidString: paneId) else { continue }
                    paneDrafts[id] = Self.draft(from: draft, store: store)
                }
            } catch {
                handleCorruptPayload(store: store, key: paneKey, data: data, error: error)
            }
        }
    }

    private static func draft(from persisted: PersistedDraft, store: any PersistenceStore) -> Draft {
        Draft(
            projectId: persisted.projectId,
            projectServerId: persisted.projectServerId,
            composerText: persisted.composerText,
            attachments: persisted.attachments.compactMap { attachment in
                guard let data = store.loadData(forKey: Self.attachmentKey(attachment.id)) else {
                    return nil
                }
                return DraftAttachment(
                    id: attachment.id,
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    kind: attachment.kind,
                    localData: data
                )
            },
            selectedHarnessId: persisted.selectedHarnessId,
            configByHarness: persisted.configByHarness,
            modeId: persisted.modeId,
            isGoalComposerArmed: persisted.isGoalComposerArmed,
            isGoalEditing: persisted.isGoalEditing,
            composerTextBeforeGoalEdit: persisted.composerTextBeforeGoalEdit
        )
    }

    private static func persisted(from draft: Draft) -> PersistedDraft {
        PersistedDraft(
            projectId: draft.projectId,
            projectServerId: draft.projectServerId,
            composerText: draft.composerText,
            attachments: draft.attachments.map {
                PersistedAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, kind: $0.kind)
            },
            selectedHarnessId: draft.selectedHarnessId,
            configByHarness: draft.configByHarness,
            modeId: draft.modeId,
            isGoalComposerArmed: draft.isGoalComposerArmed,
            isGoalEditing: draft.isGoalEditing,
            composerTextBeforeGoalEdit: draft.composerTextBeforeGoalEdit
        )
    }

    public func draft(forServer serverId: String) -> Draft? {
        drafts[serverId]
    }

    /// Finds the durable page draft whose current project targets `serverId`.
    /// A draft can live in its original machine slot after the fleet picker
    /// retargets it, so looking up only by slot would make it disappear after
    /// relaunch when New Chat restores the new target machine.
    public func draft(
        targetingServer serverId: String
    ) -> (
        slotServerId: String, draft: Draft
    )? {
        if let exact = drafts[serverId],
            (exact.projectServerId ?? serverId) == serverId
        {
            return (serverId, exact)
        }
        for slotServerId in drafts.keys.sorted() {
            guard let draft = drafts[slotServerId],
                (draft.projectServerId ?? slotServerId) == serverId
            else { continue }
            return (slotServerId, draft)
        }
        return nil
    }

    public func saveDraft(_ draft: Draft, forServer serverId: String) {
        let previousIds = Set(drafts[serverId]?.attachments.map(\.id) ?? [])
        let currentIds = Set(draft.attachments.map(\.id))
        enqueueAttachmentChanges(
            added: draft.attachments.filter { !previousIds.contains($0.id) },
            removed: previousIds.subtracting(currentIds)
        )
        drafts[serverId] = draft
        persistMetadata()
    }

    public func clearDraft(forServer serverId: String) {
        guard let draft = drafts.removeValue(forKey: serverId) else { return }
        enqueueAttachmentChanges(added: [], removed: Set(draft.attachments.map(\.id)))
        // Clearing on send supersedes any debounced keystroke snapshot. Queue
        // the empty/newest metadata immediately, but still off the main actor.
        persistMetadata(immediately: true)
    }

    // MARK: - Pane drafts

    public func paneDraft(forPane paneId: UUID) -> Draft? {
        paneDrafts[paneId]
    }

    public func savePaneDraft(_ draft: Draft, forPane paneId: UUID) {
        let previousIds = Set(paneDrafts[paneId]?.attachments.map(\.id) ?? [])
        let currentIds = Set(draft.attachments.map(\.id))
        enqueueAttachmentChanges(
            added: draft.attachments.filter { !previousIds.contains($0.id) },
            removed: previousIds.subtracting(currentIds)
        )
        paneDrafts[paneId] = draft
        persistPaneMetadata()
    }

    public func clearPaneDraft(forPane paneId: UUID) {
        guard let draft = paneDrafts.removeValue(forKey: paneId) else { return }
        enqueueAttachmentChanges(added: [], removed: Set(draft.attachments.map(\.id)))
        persistPaneMetadata(immediately: true)
    }

    public func clear() {
        let serverIds = Array(drafts.keys)
        for serverId in serverIds { clearDraft(forServer: serverId) }
        let paneIds = Array(paneDrafts.keys)
        for paneId in paneIds { clearPaneDraft(forPane: paneId) }
    }

    /// Synchronously drains the background persistence stage. Hot UI paths
    /// should never call this; lifecycle stores drain the same shared stage
    /// before termination/background suspension.
    public func flushPendingWrites() {
        persistMetadata(immediately: true)
        persistPaneMetadata(immediately: true)
        PersistenceEncoding.drain()
    }

    private func enqueueAttachmentChanges(
        added: [DraftAttachment],
        removed: Set<UUID>
    ) {
        guard !added.isEmpty || !removed.isEmpty else { return }
        let writes = added.map { (Self.attachmentKey($0.id), $0.localData) }
        let removals = removed.map(Self.attachmentKey)
        let store = store
        PersistenceEncoding.queue.async {
            do {
                for (key, data) in writes { try store.saveData(data, forKey: key) }
                for key in removals { try store.removeData(forKey: key) }
            } catch {
                Log.persistence.error(
                    "Failed to update composer draft attachments: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func persistMetadata(immediately: Bool = false) {
        let persisted = PersistedDrafts(machines: drafts.mapValues { Self.persisted(from: $0) })
        let store = store
        let key = key
        PersistenceEncoding.enqueueLatest(
            owner: persistenceOwner,
            key: key,
            delay: immediately ? 0 : 0.2
        ) {
            do {
                try store.saveData(PersistenceEncoding.encoder.encode(persisted), forKey: key)
            } catch {
                Log.persistence.error("Failed to save composer drafts: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func persistPaneMetadata(immediately: Bool = false) {
        var panes: [String: PersistedDraft] = [:]
        for (paneId, draft) in paneDrafts {
            panes[paneId.uuidString] = Self.persisted(from: draft)
        }
        let persisted = PersistedPaneDrafts(panes: panes)
        let store = store
        let paneKey = paneKey
        PersistenceEncoding.enqueueLatest(
            owner: persistenceOwner,
            key: paneKey,
            delay: immediately ? 0 : 0.2
        ) {
            do {
                try store.saveData(PersistenceEncoding.encoder.encode(persisted), forKey: paneKey)
            } catch {
                Log.persistence.error(
                    "Failed to save pane composer drafts: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func attachmentKey(_ id: UUID) -> String {
        "composer-draft-attachment-\(id.uuidString.lowercased())"
    }
}

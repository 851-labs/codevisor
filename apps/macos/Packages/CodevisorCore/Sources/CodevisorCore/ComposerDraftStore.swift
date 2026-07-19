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
        public var composerText: String
        public var attachments: [DraftAttachment]
        public var selectedHarnessId: String?
        public var runInWorktree: Bool
        public var configByHarness: [String: [String: String]]
        public var modeId: String?
        public var isGoalComposerArmed: Bool
        public var isGoalEditing: Bool
        public var composerTextBeforeGoalEdit: String?

        public init(
            projectId: UUID,
            composerText: String = "",
            attachments: [DraftAttachment] = [],
            selectedHarnessId: String? = nil,
            runInWorktree: Bool = false,
            configByHarness: [String: [String: String]] = [:],
            modeId: String? = nil,
            isGoalComposerArmed: Bool = false,
            isGoalEditing: Bool = false,
            composerTextBeforeGoalEdit: String? = nil
        ) {
            self.projectId = projectId
            self.composerText = composerText
            self.attachments = attachments
            self.selectedHarnessId = selectedHarnessId
            self.runInWorktree = runInWorktree
            self.configByHarness = configByHarness
            self.modeId = modeId
            self.isGoalComposerArmed = isGoalComposerArmed
            self.isGoalEditing = isGoalEditing
            self.composerTextBeforeGoalEdit = composerTextBeforeGoalEdit
        }
    }

    private struct PersistedAttachment: Codable {
        var id: UUID
        var name: String
        var mimeType: String
        var kind: String
    }

    private struct PersistedDraft: Codable {
        var projectId: UUID
        var composerText: String
        var attachments: [PersistedAttachment]
        var selectedHarnessId: String?
        var runInWorktree: Bool
        var configByHarness: [String: [String: String]]
        var modeId: String?
        var isGoalComposerArmed: Bool
        var isGoalEditing: Bool
        var composerTextBeforeGoalEdit: String?
    }

    private struct PersistedDrafts: Codable {
        var machines: [String: PersistedDraft]
    }

    private struct PersistedPaneDrafts: Codable {
        var panes: [String: PersistedDraft]
    }

    private let store: any PersistenceStore
    private let key: String
    private let paneKey: String
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
            runInWorktree: persisted.runInWorktree,
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
            composerText: draft.composerText,
            attachments: draft.attachments.map {
                PersistedAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, kind: $0.kind)
            },
            selectedHarnessId: draft.selectedHarnessId,
            runInWorktree: draft.runInWorktree,
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

    public func saveDraft(_ draft: Draft, forServer serverId: String) {
        let previousIds = Set(drafts[serverId]?.attachments.map(\.id) ?? [])
        let currentIds = Set(draft.attachments.map(\.id))
        do {
            for attachment in draft.attachments where !previousIds.contains(attachment.id) {
                try store.saveData(attachment.localData, forKey: Self.attachmentKey(attachment.id))
            }
            for id in previousIds.subtracting(currentIds) {
                try store.removeData(forKey: Self.attachmentKey(id))
            }
            drafts[serverId] = draft
            try persistMetadata()
        } catch {
            Log.persistence.error("Failed to save composer draft: \(String(describing: error), privacy: .public)")
        }
    }

    public func clearDraft(forServer serverId: String) {
        guard let draft = drafts.removeValue(forKey: serverId) else { return }
        do {
            for attachment in draft.attachments {
                try store.removeData(forKey: Self.attachmentKey(attachment.id))
            }
            try persistMetadata()
        } catch {
            Log.persistence.error("Failed to clear composer draft: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Pane drafts

    public func paneDraft(forPane paneId: UUID) -> Draft? {
        paneDrafts[paneId]
    }

    public func savePaneDraft(_ draft: Draft, forPane paneId: UUID) {
        let previousIds = Set(paneDrafts[paneId]?.attachments.map(\.id) ?? [])
        let currentIds = Set(draft.attachments.map(\.id))
        do {
            for attachment in draft.attachments where !previousIds.contains(attachment.id) {
                try store.saveData(attachment.localData, forKey: Self.attachmentKey(attachment.id))
            }
            for id in previousIds.subtracting(currentIds) {
                try store.removeData(forKey: Self.attachmentKey(id))
            }
            paneDrafts[paneId] = draft
            try persistPaneMetadata()
        } catch {
            Log.persistence.error("Failed to save pane composer draft: \(String(describing: error), privacy: .public)")
        }
    }

    public func clearPaneDraft(forPane paneId: UUID) {
        guard let draft = paneDrafts.removeValue(forKey: paneId) else { return }
        do {
            for attachment in draft.attachments {
                try store.removeData(forKey: Self.attachmentKey(attachment.id))
            }
            try persistPaneMetadata()
        } catch {
            Log.persistence.error("Failed to clear pane composer draft: \(String(describing: error), privacy: .public)")
        }
    }

    public func clear() {
        let serverIds = Array(drafts.keys)
        for serverId in serverIds { clearDraft(forServer: serverId) }
        let paneIds = Array(paneDrafts.keys)
        for paneId in paneIds { clearPaneDraft(forPane: paneId) }
    }

    private func persistMetadata() throws {
        let persisted = PersistedDrafts(machines: drafts.mapValues { Self.persisted(from: $0) })
        try store.saveData(JSONEncoder().encode(persisted), forKey: key)
    }

    private func persistPaneMetadata() throws {
        var panes: [String: PersistedDraft] = [:]
        for (paneId, draft) in paneDrafts {
            panes[paneId.uuidString] = Self.persisted(from: draft)
        }
        try store.saveData(JSONEncoder().encode(PersistedPaneDrafts(panes: panes)), forKey: paneKey)
    }

    private static func attachmentKey(_ id: UUID) -> String {
        "composer-draft-attachment-\(id.uuidString.lowercased())"
    }
}

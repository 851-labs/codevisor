import Foundation

@MainActor
public final class ComposerDraftStore {
  public struct DraftAttachment: Equatable {
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var kind: String
    public var fileURL: URL

    public init(id: UUID, name: String, mimeType: String, kind: String, fileURL: URL) {
      self.id = id
      self.name = name
      self.mimeType = mimeType
      self.kind = kind
      self.fileURL = fileURL
    }
  }

  public struct Draft: Equatable {
    public var projectId: UUID
    public var projectServerId: String?
    public var composerText: String
    public var attachments: [DraftAttachment]
    public var selectedHarnessId: String?
    public var configByHarness: [String: [String: String]]
    public var modeId: String?
    public var isGoalComposerArmed: Bool
    public var isGoalEditing: Bool
    public var composerTextBeforeGoalEdit: String?
    public var usesImmediateDefaultsPersistence: Bool
    public var selectionWasAutomaticallyCarried: Bool

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
      composerTextBeforeGoalEdit: String? = nil,
      usesImmediateDefaultsPersistence: Bool = true,
      selectionWasAutomaticallyCarried: Bool = false
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
      self.usesImmediateDefaultsPersistence = usesImmediateDefaultsPersistence
      self.selectionWasAutomaticallyCarried = selectionWasAutomaticallyCarried
    }
  }

  struct Persisted: Sendable {
    var machines: ComposerPersistedDrafts?
    var panes: ComposerPersistedPaneDrafts?
  }

  public nonisolated static let defaultKey = "composer-drafts"
  public nonisolated static let defaultPaneKey = "composer-pane-drafts"

  private let store: any PersistenceStore
  private let key: String
  private let paneKey: String
  private let persistenceOwner = UUID()
  public let attachmentFiles: ComposerAttachmentFileStore
  private var drafts: [String: Draft] = [:]
  private var paneDrafts: [UUID: Draft] = [:]

  public convenience init(
    store: any PersistenceStore,
    attachmentFiles: ComposerAttachmentFileStore = .temporary(),
    key: String = ComposerDraftStore.defaultKey,
    paneKey: String = ComposerDraftStore.defaultPaneKey
  ) {
    PersistenceEncoding.drain()
    self.init(
      store: store, attachmentFiles: attachmentFiles, key: key, paneKey: paneKey,
      persisted: Self.loadPersisted(from: store, key: key, paneKey: paneKey))
  }

  public convenience init(
    store: any PersistenceStore,
    attachmentFiles: ComposerAttachmentFileStore,
    launchSnapshot: ClientLaunchSnapshot?
  ) {
    guard let launchSnapshot else {
      self.init(store: store, attachmentFiles: attachmentFiles)
      return
    }
    self.init(
      store: store, attachmentFiles: attachmentFiles, key: Self.defaultKey, paneKey: Self.defaultPaneKey,
      persisted: launchSnapshot.composerDrafts)
  }

  private init(
    store: any PersistenceStore,
    attachmentFiles: ComposerAttachmentFileStore,
    key: String,
    paneKey: String,
    persisted: Persisted
  ) {
    self.store = store
    self.attachmentFiles = attachmentFiles
    self.key = key
    self.paneKey = paneKey
    var migratedBlobKeys: [String] = []
    if let machines = persisted.machines {
      drafts = machines.machines.mapValues {
        ComposerPersistedDraft.draft(
          from: $0, store: store, files: attachmentFiles, migratedBlobKeys: &migratedBlobKeys)
      }
    }
    if let panes = persisted.panes {
      for (paneId, draft) in panes.panes {
        guard let id = UUID(uuidString: paneId) else { continue }
        paneDrafts[id] = ComposerPersistedDraft.draft(
          from: draft, store: store, files: attachmentFiles, migratedBlobKeys: &migratedBlobKeys)
      }
    }
    if !migratedBlobKeys.isEmpty {
      finishLegacyAttachmentMigration(removing: migratedBlobKeys)
    }
  }

  nonisolated static func loadPersisted(
    from store: any PersistenceStore,
    key: String = defaultKey,
    paneKey: String = defaultPaneKey
  ) -> Persisted {
    let decoder = JSONDecoder()
    var persisted = Persisted()
    if let data = store.loadData(forKey: key) {
      do {
        persisted.machines = try decoder.decode(ComposerPersistedDrafts.self, from: data)
      } catch {
        handleCorruptPayload(store: store, key: key, data: data, error: error)
      }
    }
    if let data = store.loadData(forKey: paneKey) {
      do {
        persisted.panes = try decoder.decode(ComposerPersistedPaneDrafts.self, from: data)
      } catch {
        handleCorruptPayload(store: store, key: paneKey, data: data, error: error)
      }
    }
    return persisted
  }

  public func draft(forServer serverId: String) -> Draft? {
    drafts[serverId]
  }

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
    drafts[serverId] = draft
    persistMetadata()
  }

  public func clearDraft(forServer serverId: String) {
    guard drafts.removeValue(forKey: serverId) != nil else { return }
    persistMetadata(immediately: true)
  }

  public func paneDraft(forPane paneId: UUID) -> Draft? {
    paneDrafts[paneId]
  }

  public func savePaneDraft(_ draft: Draft, forPane paneId: UUID) {
    paneDrafts[paneId] = draft
    persistPaneMetadata()
  }

  public func clearPaneDraft(forPane paneId: UUID) {
    guard paneDrafts.removeValue(forKey: paneId) != nil else { return }
    persistPaneMetadata(immediately: true)
  }

  public func clear() {
    let serverIds = Array(drafts.keys)
    for serverId in serverIds { clearDraft(forServer: serverId) }
    let paneIds = Array(paneDrafts.keys)
    for paneId in paneIds { clearPaneDraft(forPane: paneId) }
  }

  public func removeUnreferencedAttachmentFiles() {
    let referenced = Set(
      (Array(drafts.values) + Array(paneDrafts.values)).flatMap { $0.attachments.map(\.id) })
    let files = attachmentFiles
    let cutoff = Date()
    PersistenceEncoding.queue.async {
      files.removeAll(except: referenced, createdBefore: cutoff)
    }
  }

  private func finishLegacyAttachmentMigration(removing blobKeys: [String]) {
    let files = attachmentFiles
    let machines = ComposerPersistedDrafts(
      machines: drafts.mapValues { ComposerPersistedDraft.persisted(from: $0, files: files) })
    var panes: [String: ComposerPersistedDraft] = [:]
    for (paneId, draft) in paneDrafts {
      panes[paneId.uuidString] = ComposerPersistedDraft.persisted(from: draft, files: files)
    }
    let paneDrafts = ComposerPersistedPaneDrafts(panes: panes)
    let store = store
    let key = key
    let paneKey = paneKey
    PersistenceEncoding.queue.async {
      do {
        try store.saveData(PersistenceEncoding.encoder.encode(machines), forKey: key)
        try store.saveData(PersistenceEncoding.encoder.encode(paneDrafts), forKey: paneKey)
        for blobKey in blobKeys { try store.removeData(forKey: blobKey) }
      } catch {
        Log.persistence.error(
          "Failed to migrate composer draft attachments: \(String(describing: error), privacy: .public)")
      }
    }
  }

  private func persistMetadata(immediately: Bool = false) {
    let files = attachmentFiles
    let persisted = ComposerPersistedDrafts(
      machines: drafts.mapValues { ComposerPersistedDraft.persisted(from: $0, files: files) })
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
    var panes: [String: ComposerPersistedDraft] = [:]
    for (paneId, draft) in paneDrafts {
      panes[paneId.uuidString] = ComposerPersistedDraft.persisted(from: draft, files: attachmentFiles)
    }
    let persisted = ComposerPersistedPaneDrafts(panes: panes)
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

}

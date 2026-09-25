import Foundation

/// Persists the complete unsent new-chat composer per machine. Attachments
/// persist as references to their staged files in `attachmentFiles`, so
/// editing text never rewrites large blobs. The composer that staged a file
/// owns deleting it; clearing a draft only drops the reference, because a
/// promoted draft's controller still holds (and may restore) the files.
@MainActor
public final class ComposerDraftStore {
  public struct DraftAttachment: Equatable {
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var kind: String
    /// The staged copy inside the store's `attachmentFiles`.
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
    /// Newer drafts have already persisted every explicit picker change to
    /// composer defaults. Older drafts need a one-time compatibility
    /// promotion when restored.
    public var usesImmediateDefaultsPersistence: Bool
    /// True when this draft is temporarily carrying a compatible
    /// selection from another machine instead of using this machine's
    /// durable fallback profile.
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

  private struct PersistedAttachment: Codable, Sendable {
    var id: UUID
    var name: String
    var mimeType: String
    var kind: String
    /// "<id>/<name>" inside `attachmentFiles`. Absent in drafts written
    /// before staging, whose bytes live under `attachmentKey(id)`.
    var stagedPath: String?
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
    var usesImmediateDefaultsPersistence: Bool?
    var selectionWasAutomaticallyCarried: Bool?
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
  /// Where drafted attachments are staged; composers share it.
  public let attachmentFiles: ComposerAttachmentFileStore
  private var drafts: [String: Draft] = [:]
  /// In-workspace draft chat panes, keyed by pane id. Same schema as the
  /// per-machine draft — an unsent in-workspace composer must survive
  /// relaunches and app updates just like the page draft does.
  private var paneDrafts: [UUID: Draft] = [:]

  public init(
    store: any PersistenceStore,
    attachmentFiles: ComposerAttachmentFileStore = .temporary(),
    key: String = "composer-drafts",
    paneKey: String = "composer-pane-drafts"
  ) {
    // Flush a previous instance's coalesced snapshot before replacing an
    // environment or reopening the store in tests.
    PersistenceEncoding.drain()
    self.store = store
    self.attachmentFiles = attachmentFiles
    self.key = key
    self.paneKey = paneKey
    var migratedBlobKeys: [String] = []
    if let data = store.loadData(forKey: key) {
      do {
        let persisted = try JSONDecoder().decode(PersistedDrafts.self, from: data)
        drafts = persisted.machines.mapValues {
          Self.draft(from: $0, store: store, files: attachmentFiles, migratedBlobKeys: &migratedBlobKeys)
        }
      } catch {
        handleCorruptPayload(store: store, key: key, data: data, error: error)
      }
    }
    if let data = store.loadData(forKey: paneKey) {
      do {
        let persisted = try JSONDecoder().decode(PersistedPaneDrafts.self, from: data)
        for (paneId, draft) in persisted.panes {
          guard let id = UUID(uuidString: paneId) else { continue }
          paneDrafts[id] = Self.draft(
            from: draft, store: store, files: attachmentFiles, migratedBlobKeys: &migratedBlobKeys)
        }
      } catch {
        handleCorruptPayload(store: store, key: paneKey, data: data, error: error)
      }
    }
    if !migratedBlobKeys.isEmpty {
      finishLegacyAttachmentMigration(removing: migratedBlobKeys)
    }
  }

  private static func draft(
    from persisted: PersistedDraft,
    store: any PersistenceStore,
    files: ComposerAttachmentFileStore,
    migratedBlobKeys: inout [String]
  ) -> Draft {
    Draft(
      projectId: persisted.projectId,
      projectServerId: persisted.projectServerId,
      composerText: persisted.composerText,
      attachments: persisted.attachments.compactMap { attachment in
        let fileURL: URL
        if let stagedPath = attachment.stagedPath {
          guard let url = files.fileURL(forRelativePath: stagedPath),
            FileManager.default.fileExists(atPath: url.path)
          else { return nil }
          fileURL = url
        } else {
          // A draft from before staging: move its blob into a staged file
          // once, then persist the reference instead.
          let blobKey = Self.attachmentKey(attachment.id)
          guard let data = store.loadData(forKey: blobKey),
            let url = try? files.stage(data: data, id: attachment.id, name: attachment.name)
          else { return nil }
          migratedBlobKeys.append(blobKey)
          fileURL = url
        }
        return DraftAttachment(
          id: attachment.id,
          name: attachment.name,
          mimeType: attachment.mimeType,
          kind: attachment.kind,
          fileURL: fileURL
        )
      },
      selectedHarnessId: persisted.selectedHarnessId,
      configByHarness: persisted.configByHarness,
      modeId: persisted.modeId,
      isGoalComposerArmed: persisted.isGoalComposerArmed,
      isGoalEditing: persisted.isGoalEditing,
      composerTextBeforeGoalEdit: persisted.composerTextBeforeGoalEdit,
      // Absence identifies a draft written before explicit selections
      // were persisted immediately.
      usesImmediateDefaultsPersistence: persisted.usesImmediateDefaultsPersistence ?? false,
      selectionWasAutomaticallyCarried: persisted.selectionWasAutomaticallyCarried ?? false
    )
  }

  private static func persisted(from draft: Draft, files: ComposerAttachmentFileStore) -> PersistedDraft {
    PersistedDraft(
      projectId: draft.projectId,
      projectServerId: draft.projectServerId,
      composerText: draft.composerText,
      attachments: draft.attachments.compactMap {
        // A file outside the staging folder can't be referenced portably.
        guard let stagedPath = files.relativePath(of: $0.fileURL) else { return nil }
        return PersistedAttachment(
          id: $0.id, name: $0.name, mimeType: $0.mimeType, kind: $0.kind, stagedPath: stagedPath)
      },
      selectedHarnessId: draft.selectedHarnessId,
      configByHarness: draft.configByHarness,
      modeId: draft.modeId,
      isGoalComposerArmed: draft.isGoalComposerArmed,
      isGoalEditing: draft.isGoalEditing,
      composerTextBeforeGoalEdit: draft.composerTextBeforeGoalEdit,
      usesImmediateDefaultsPersistence: draft.usesImmediateDefaultsPersistence,
      selectionWasAutomaticallyCarried: draft.selectionWasAutomaticallyCarried
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
    drafts[serverId] = draft
    persistMetadata()
  }

  public func clearDraft(forServer serverId: String) {
    guard drafts.removeValue(forKey: serverId) != nil else { return }
    // Clearing on send supersedes any debounced keystroke snapshot. Queue
    // the empty/newest metadata immediately, but still off the main actor.
    persistMetadata(immediately: true)
  }

  // MARK: - Pane drafts

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

  /// Synchronously drains the background persistence stage. Hot UI paths
  /// should never call this; lifecycle stores drain the same shared stage
  /// before termination/background suspension.
  public func flushPendingWrites() {
    persistMetadata(immediately: true)
    persistPaneMetadata(immediately: true)
    PersistenceEncoding.drain()
  }

  /// Deletes staged files no draft references — leftovers from composers
  /// that were closed, crashed, or never persisted. Call once at launch,
  /// before any composer can stage; files staged after the call are spared.
  public func removeUnreferencedAttachmentFiles() {
    let referenced = Set(
      (Array(drafts.values) + Array(paneDrafts.values)).flatMap { $0.attachments.map(\.id) })
    let files = attachmentFiles
    let cutoff = Date()
    PersistenceEncoding.queue.async {
      files.removeAll(except: referenced, createdBefore: cutoff)
    }
  }

  /// Rewrites the metadata with staged-file references, then drops the
  /// legacy blobs — in one job, so a crash between the two can't leave a
  /// draft whose attachments exist nowhere.
  private func finishLegacyAttachmentMigration(removing blobKeys: [String]) {
    let files = attachmentFiles
    let machines = PersistedDrafts(machines: drafts.mapValues { Self.persisted(from: $0, files: files) })
    var panes: [String: PersistedDraft] = [:]
    for (paneId, draft) in paneDrafts {
      panes[paneId.uuidString] = Self.persisted(from: draft, files: files)
    }
    let paneDrafts = PersistedPaneDrafts(panes: panes)
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
    let persisted = PersistedDrafts(machines: drafts.mapValues { Self.persisted(from: $0, files: files) })
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
      panes[paneId.uuidString] = Self.persisted(from: draft, files: attachmentFiles)
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

  /// Where drafts from before staging kept each attachment's bytes.
  private static func attachmentKey(_ id: UUID) -> String {
    "composer-draft-attachment-\(id.uuidString.lowercased())"
  }
}

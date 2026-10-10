import Foundation

struct ComposerPersistedAttachment: Codable, Sendable {
  var id: UUID
  var name: String
  var mimeType: String
  var kind: String
  /// "<id>/<name>" inside `attachmentFiles`. Absent in drafts written
  /// before staging, whose bytes live under `attachmentKey(id)`.
  var stagedPath: String?
}

struct ComposerPersistedDraft: Codable, Sendable {
  var projectId: UUID
  var projectServerId: String?
  var composerText: String
  var attachments: [ComposerPersistedAttachment]
  var selectedHarnessId: String?
  var configByHarness: [String: [String: String]]
  var modeId: String?
  var isGoalComposerArmed: Bool
  var isGoalEditing: Bool
  var composerTextBeforeGoalEdit: String?
  var usesImmediateDefaultsPersistence: Bool?
  var selectionWasAutomaticallyCarried: Bool?

  @MainActor
  static func draft(
    from persisted: ComposerPersistedDraft,
    store: any PersistenceStore,
    files: ComposerAttachmentFileStore,
    migratedBlobKeys: inout [String]
  ) -> ComposerDraftStore.Draft {
    ComposerDraftStore.Draft(
      projectId: persisted.projectId,
      projectServerId: persisted.projectServerId,
      composerText: persisted.composerText,
      attachments: persisted.attachments.compactMap { attachment in
        Self.restoreDraftAttachment(
          attachment, store: store, files: files, migratedBlobKeys: &migratedBlobKeys)
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

  @MainActor
  private static func restoreDraftAttachment(
    _ attachment: ComposerPersistedAttachment,
    store: any PersistenceStore,
    files: ComposerAttachmentFileStore,
    migratedBlobKeys: inout [String]
  ) -> ComposerDraftStore.DraftAttachment? {
    let fileURL: URL
    if let stagedPath = attachment.stagedPath {
      guard let url = files.fileURL(forRelativePath: stagedPath),
        FileManager.default.fileExists(atPath: url.path)
      else { return nil }
      fileURL = url
    } else {
      guard
        let url = Self.stageLegacyDraftAttachment(
          attachment, store: store, files: files, migratedBlobKeys: &migratedBlobKeys)
      else { return nil }
      fileURL = url
    }
    return ComposerDraftStore.DraftAttachment(
      id: attachment.id,
      name: attachment.name,
      mimeType: attachment.mimeType,
      kind: attachment.kind,
      fileURL: fileURL
    )
  }

  @MainActor
  private static func stageLegacyDraftAttachment(
    _ attachment: ComposerPersistedAttachment,
    store: any PersistenceStore,
    files: ComposerAttachmentFileStore,
    migratedBlobKeys: inout [String]
  ) -> URL? {
    // A draft from before staging: move its blob into a staged file
    // once, then persist the reference instead.
    let blobKey = Self.attachmentKey(attachment.id)
    guard let data = store.loadData(forKey: blobKey),
      let url = try? files.stage(data: data, id: attachment.id, name: attachment.name)
    else { return nil }
    migratedBlobKeys.append(blobKey)
    return url
  }

  @MainActor
  static func persisted(
    from draft: ComposerDraftStore.Draft, files: ComposerAttachmentFileStore
  ) -> ComposerPersistedDraft {
    ComposerPersistedDraft(
      projectId: draft.projectId,
      projectServerId: draft.projectServerId,
      composerText: draft.composerText,
      attachments: draft.attachments.compactMap {
        // A file outside the staging folder can't be referenced portably.
        guard let stagedPath = files.relativePath(of: $0.fileURL) else { return nil }
        return ComposerPersistedAttachment(
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

  /// Where drafts from before staging kept each attachment's bytes.
  @MainActor
  private static func attachmentKey(_ id: UUID) -> String {
    "composer-draft-attachment-\(id.uuidString.lowercased())"
  }
}

struct ComposerPersistedDrafts: Codable, Sendable {
  var machines: [String: ComposerPersistedDraft]
}

struct ComposerPersistedPaneDrafts: Codable, Sendable {
  var panes: [String: ComposerPersistedDraft]
}

import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("ComposerDraftStore")
struct ComposerDraftStoreTests {
  @Test("Draft project restoration preserves real and placeholder targets")
  func restoresDraftProject() {
    let project = Project.fromFolder(
      URL(fileURLWithPath: "/srv/project"),
      serverId: "remote-b"
    )
    let savedProject = ComposerDraftStore.Draft(
      projectId: project.id,
      projectServerId: project.serverId
    )
    let savedPlaceholder = ComposerDraftStore.Draft(
      projectId: Project.runTargetPlaceholderID,
      projectServerId: "fresh-vnc"
    )

    #expect(savedProject.restoredProject(in: [project], defaultServerId: "local") == project)
    let placeholder = savedPlaceholder.restoredProject(in: [project], defaultServerId: "local")
    #expect(placeholder?.isRunTargetPlaceholder == true)
    #expect(placeholder?.serverId == "fresh-vnc")
    #expect(
      ComposerDraftStore.Draft(projectId: UUID()).restoredProject(
        in: [project],
        defaultServerId: "local"
      ) == nil
    )
  }

  @Test("A draft pointing at a scratch folder restores as No project")
  func scratchDraftRestoresAsNoProject() {
    var scratch = Project.fromFolder(URL(fileURLWithPath: "/tmp/workspaces/burrito"))
    scratch.isScratch = true
    let saved = ComposerDraftStore.Draft(projectId: scratch.id, projectServerId: "local")
    let restored = saved.restoredProject(in: [scratch], defaultServerId: "local")
    #expect(restored?.isRunTargetPlaceholder == true)
    #expect(restored?.serverId == "local")
  }

  @Test("A draft targeting another machine's project persists its server id")
  func crossMachineDraftPersists() {
    let store = InMemoryStore()
    let expected = ComposerDraftStore.Draft(
      projectId: UUID(),
      projectServerId: "remote-b",
      composerText: "send this to the studio machine"
    )
    ComposerDraftStore(store: store).saveDraft(expected, forServer: "local")
    // Reloaded from disk: the FOREIGN project reference survives, still
    // under the machine slot the draft was typed on.
    let reloaded = ComposerDraftStore(store: store)
    #expect(reloaded.draft(forServer: "local") == expected)
    #expect(reloaded.draft(forServer: "local")?.projectServerId == "remote-b")
    let targeted = reloaded.draft(targetingServer: "remote-b")
    #expect(targeted?.slotServerId == "local")
    #expect(targeted?.draft == expected)
  }

  /// A fresh staging folder; each test removes it with `cleanUp()`.
  private struct StagingFolder {
    let files = ComposerAttachmentFileStore.temporary()

    func cleanUp() { try? FileManager.default.removeItem(at: files.root) }

    func stage(_ bytes: [UInt8], name: String, id: UUID = UUID()) throws -> ComposerDraftStore.DraftAttachment {
      .init(
        id: id,
        name: name,
        mimeType: "text/plain",
        kind: "file",
        fileURL: try files.stage(data: Data(bytes), id: id, name: name)
      )
    }
  }

  @Test("Pane drafts persist per pane, with staged attachment references, across instances")
  func paneDraftsPersist() throws {
    let store = InMemoryStore()
    let staging = StagingFolder()
    defer { staging.cleanUp() }
    let paneId = UUID()
    let expected = ComposerDraftStore.Draft(
      projectId: UUID(),
      composerText: "in-workspace unsent prompt",
      attachments: [try staging.stage([9, 8, 7], name: "log.txt")],
      selectedHarnessId: "claude-code",
      configByHarness: ["claude-code": ["model": "opus"]]
    )
    ComposerDraftStore(store: store, attachmentFiles: staging.files).savePaneDraft(expected, forPane: paneId)
    let reloaded = ComposerDraftStore(store: store, attachmentFiles: staging.files)
    #expect(reloaded.paneDraft(forPane: paneId) == expected)
    // Other panes and the per-machine draft stay untouched.
    #expect(reloaded.paneDraft(forPane: UUID()) == nil)
    #expect(reloaded.draft(forServer: "local") == nil)
  }

  @Test("Clearing a promoted pane draft keeps the staged files its composer still holds")
  func clearPaneDraftKeepsStagedFiles() throws {
    let store = InMemoryStore()
    let staging = StagingFolder()
    defer { staging.cleanUp() }
    let paneId = UUID()
    let attachment = try staging.stage([1], name: "a.txt")
    let drafts = ComposerDraftStore(store: store, attachmentFiles: staging.files)
    drafts.savePaneDraft(.init(projectId: UUID(), attachments: [attachment]), forPane: paneId)

    drafts.clearPaneDraft(forPane: paneId)
    drafts.flushPendingWrites()

    #expect(ComposerDraftStore(store: store, attachmentFiles: staging.files).paneDraft(forPane: paneId) == nil)
    // A failed first send restores the composer from these files.
    #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
  }

  @Test("Drafts from before staging move their attachment blobs into staged files")
  func legacyAttachmentBlobMigrates() throws {
    let staging = StagingFolder()
    defer { staging.cleanUp() }
    let attachmentId = UUID()
    let blobKey = "composer-draft-attachment-\(attachmentId.uuidString.lowercased())"
    let metadata = """
      {
        "machines": {
          "local": {
            "projectId": "\(UUID().uuidString)",
            "composerText": "legacy draft",
            "attachments": [
              {"id": "\(attachmentId.uuidString)", "name": "notes.txt", "mimeType": "text/plain", "kind": "file"}
            ],
            "configByHarness": {},
            "isGoalComposerArmed": false,
            "isGoalEditing": false
          }
        }
      }
      """
    let store = InMemoryStore(storage: [
      "composer-drafts": Data(metadata.utf8),
      blobKey: Data("notes".utf8),
    ])

    let drafts = ComposerDraftStore(store: store, attachmentFiles: staging.files)
    drafts.flushPendingWrites()

    let migrated = try #require(drafts.draft(forServer: "local")?.attachments.first)
    #expect(migrated.id == attachmentId)
    #expect(try Data(contentsOf: migrated.fileURL) == Data("notes".utf8))
    #expect(store.loadData(forKey: blobKey) == nil)
    // Reopened, the draft resolves the staged-file reference it now persists.
    let reopened = ComposerDraftStore(store: store, attachmentFiles: staging.files)
    #expect(reopened.draft(forServer: "local")?.attachments == [migrated])
  }

  @Test("The launch sweep deletes staged files that no draft references")
  func launchSweepKeepsOnlyDraftedFiles() throws {
    let store = InMemoryStore()
    let staging = StagingFolder()
    defer { staging.cleanUp() }
    let drafted = try staging.stage([1], name: "drafted.txt")
    let orphan = try staging.stage([2], name: "orphan.txt")
    ComposerDraftStore(store: store, attachmentFiles: staging.files)
      .saveDraft(.init(projectId: UUID(), attachments: [drafted]), forServer: "local")

    let relaunched = ComposerDraftStore(store: store, attachmentFiles: staging.files)
    relaunched.removeUnreferencedAttachmentFiles()
    relaunched.flushPendingWrites()

    #expect(FileManager.default.fileExists(atPath: drafted.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: orphan.fileURL.path))
  }

  @Test("clear() wipes pane drafts too")
  func clearWipesPaneDrafts() {
    let store = InMemoryStore()
    let drafts = ComposerDraftStore(store: store)
    let paneId = UUID()
    drafts.savePaneDraft(.init(projectId: UUID(), composerText: "x"), forPane: paneId)
    drafts.saveDraft(.init(projectId: UUID(), composerText: "y"), forServer: "local")
    drafts.clear()
    let reloaded = ComposerDraftStore(store: store)
    #expect(reloaded.draft(forServer: "local") == nil)
    #expect(reloaded.paneDraft(forPane: paneId) == nil)
  }

  @Test("Persists the complete unsent draft across instances")
  func persistsCompleteDraft() throws {
    let store = InMemoryStore()
    let staging = StagingFolder()
    defer { staging.cleanUp() }
    let projectId = UUID()
    let expected = ComposerDraftStore.Draft(
      projectId: projectId,
      composerText: "unsent prompt",
      attachments: [try staging.stage([1, 2, 3], name: "diagram.png")],
      selectedHarnessId: "codex",
      configByHarness: [
        "codex": ["model": "gpt-5.5", "thought_level": "high"]
      ],
      modeId: "plan",
      isGoalComposerArmed: true,
      isGoalEditing: false,
      composerTextBeforeGoalEdit: "ordinary draft"
    )

    ComposerDraftStore(store: store, attachmentFiles: staging.files).saveDraft(expected, forServer: "local")

    #expect(ComposerDraftStore(store: store, attachmentFiles: staging.files).draft(forServer: "local") == expected)
  }

  @Test("Drafts from before immediate defaults persistence request one compatibility backfill")
  func legacyDraftRequestsDefaultsBackfill() throws {
    let projectId = UUID()
    let metadata = """
      {
        "machines": {
          "machine-b": {
            "projectId": "\(projectId.uuidString)",
            "composerText": "legacy draft",
            "attachments": [],
            "selectedHarnessId": "codex",
            "configByHarness": {"codex": {"model": "gpt-5.6-sol"}},
            "isGoalComposerArmed": false,
            "isGoalEditing": false
          }
        }
      }
      """
    let store = InMemoryStore(storage: [
      "composer-drafts": try #require(metadata.data(using: .utf8))
    ])

    let draft = try #require(ComposerDraftStore(store: store).draft(forServer: "machine-b"))

    #expect(!draft.usesImmediateDefaultsPersistence)
  }

  @Test("Keeps machines isolated")
  func machineIsolation() {
    let store = InMemoryStore()
    let drafts = ComposerDraftStore(store: store)
    let local = ComposerDraftStore.Draft(projectId: UUID(), composerText: "local")
    let remote = ComposerDraftStore.Draft(projectId: UUID(), composerText: "remote")

    drafts.saveDraft(local, forServer: "local")
    drafts.saveDraft(remote, forServer: "remote-a")

    let reopened = ComposerDraftStore(store: store)
    #expect(reopened.draft(forServer: "local") == local)
    #expect(reopened.draft(forServer: "remote-a") == remote)
  }

  @Test("Corrupted metadata opens empty")
  func corruptedMetadata() {
    let store = InMemoryStore(storage: ["composer-drafts": Data("nope".utf8)])
    #expect(ComposerDraftStore(store: store).draft(forServer: "local") == nil)
  }
}

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

  @Test("Pane drafts persist per pane, with attachment bytes, across instances")
  func paneDraftsPersist() {
    let store = InMemoryStore()
    let paneId = UUID()
    let attachmentId = UUID()
    let expected = ComposerDraftStore.Draft(
      projectId: UUID(),
      composerText: "in-workspace unsent prompt",
      attachments: [
        .init(
          id: attachmentId,
          name: "log.txt",
          mimeType: "text/plain",
          kind: "file",
          localData: Data([9, 8, 7])
        )
      ],
      selectedHarnessId: "claude-code",
      configByHarness: ["claude-code": ["model": "opus"]]
    )
    ComposerDraftStore(store: store).savePaneDraft(expected, forPane: paneId)
    let reloaded = ComposerDraftStore(store: store)
    #expect(reloaded.paneDraft(forPane: paneId) == expected)
    // Other panes and the per-machine draft stay untouched.
    #expect(reloaded.paneDraft(forPane: UUID()) == nil)
    #expect(reloaded.draft(forServer: "local") == nil)
  }

  @Test("Clearing a pane draft removes its attachment bytes")
  func clearPaneDraftRemovesAttachments() {
    let store = InMemoryStore()
    let paneId = UUID()
    let attachmentId = UUID()
    let drafts = ComposerDraftStore(store: store)
    drafts.savePaneDraft(
      .init(
        projectId: UUID(),
        attachments: [
          .init(id: attachmentId, name: "a", mimeType: "image/png", kind: "image", localData: Data([1]))
        ]
      ),
      forPane: paneId
    )
    let attachmentKey = "composer-draft-attachment-\(attachmentId.uuidString.lowercased())"
    drafts.flushPendingWrites()
    #expect(store.loadData(forKey: attachmentKey) != nil)
    drafts.clearPaneDraft(forPane: paneId)
    drafts.flushPendingWrites()
    #expect(store.loadData(forKey: attachmentKey) == nil)
    #expect(ComposerDraftStore(store: store).paneDraft(forPane: paneId) == nil)
  }

  @Test("clear() wipes pane drafts too")
  func clearWipesPaneDrafts() {
    let store = InMemoryStore()
    let drafts = ComposerDraftStore(store: store)
    drafts.savePaneDraft(.init(projectId: UUID(), composerText: "x"), forPane: UUID())
    drafts.saveDraft(.init(projectId: UUID(), composerText: "y"), forServer: "local")
    drafts.clear()
    let reloaded = ComposerDraftStore(store: store)
    #expect(reloaded.draft(forServer: "local") == nil)
  }

  @Test("Persists the complete unsent draft across instances")
  func persistsCompleteDraft() {
    let store = InMemoryStore()
    let projectId = UUID()
    let attachmentId = UUID()
    let expected = ComposerDraftStore.Draft(
      projectId: projectId,
      composerText: "unsent prompt",
      attachments: [
        .init(
          id: attachmentId,
          name: "diagram.png",
          mimeType: "image/png",
          kind: "image",
          localData: Data([1, 2, 3])
        )
      ],
      selectedHarnessId: "codex",
      configByHarness: [
        "codex": ["model": "gpt-5.5", "thought_level": "high"]
      ],
      modeId: "plan",
      isGoalComposerArmed: true,
      isGoalEditing: false,
      composerTextBeforeGoalEdit: "ordinary draft"
    )

    ComposerDraftStore(store: store).saveDraft(expected, forServer: "local")

    #expect(ComposerDraftStore(store: store).draft(forServer: "local") == expected)
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

  @Test("Replacing and clearing a draft removes attachment bytes")
  func attachmentCleanup() {
    let store = InMemoryStore()
    let attachmentId = UUID()
    let attachment = ComposerDraftStore.DraftAttachment(
      id: attachmentId,
      name: "notes.txt",
      mimeType: "text/plain",
      kind: "file",
      localData: Data("notes".utf8)
    )
    let drafts = ComposerDraftStore(store: store)
    drafts.saveDraft(
      .init(projectId: UUID(), attachments: [attachment]),
      forServer: "local"
    )
    drafts.flushPendingWrites()
    #expect(store.loadData(forKey: "composer-draft-attachment-\(attachmentId.uuidString.lowercased())") != nil)

    drafts.saveDraft(.init(projectId: UUID()), forServer: "local")
    drafts.flushPendingWrites()
    #expect(store.loadData(forKey: "composer-draft-attachment-\(attachmentId.uuidString.lowercased())") == nil)

    drafts.clearDraft(forServer: "local")
    #expect(ComposerDraftStore(store: store).draft(forServer: "local") == nil)
  }

  @Test("Corrupted metadata opens empty")
  func corruptedMetadata() {
    let store = InMemoryStore(storage: ["composer-drafts": Data("nope".utf8)])
    #expect(ComposerDraftStore(store: store).draft(forServer: "local") == nil)
  }
}

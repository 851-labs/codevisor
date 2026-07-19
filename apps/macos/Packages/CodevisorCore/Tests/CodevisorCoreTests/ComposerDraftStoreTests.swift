import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("ComposerDraftStore")
struct ComposerDraftStoreTests {
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
        #expect(store.loadData(forKey: attachmentKey) != nil)
        drafts.clearPaneDraft(forPane: paneId)
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
            runInWorktree: false,
            // An existing-worktree selection (mutually exclusive with
            // runInWorktree) must survive the roundtrip too.
            worktreeName: "ada-lovelace",
            worktreeCwd: "/tmp/worktrees/ada-lovelace",
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
        #expect(store.loadData(forKey: "composer-draft-attachment-\(attachmentId.uuidString.lowercased())") != nil)

        drafts.saveDraft(.init(projectId: UUID()), forServer: "local")
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

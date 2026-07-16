import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("ComposerDraftStore")
struct ComposerDraftStoreTests {
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
            runInWorktree: true,
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

import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("NewWorkspaceDefaultsStore")
struct NewWorkspaceDefaultsStoreTests {
    @Test("Starts empty")
    func startsEmpty() {
        let store = NewWorkspaceDefaultsStore(store: InMemoryStore())
        #expect(store.defaults(forServer: "local") == nil)
    }

    @Test("Remembers per machine and persists across instances")
    func remembersAndPersists() {
        let backing = InMemoryStore()
        let projectId = UUID()
        let expected = NewWorkspaceDefaultsStore.Defaults(
            projectId: projectId,
            startingTab: "terminal",
            newWorktree: true
        )
        NewWorkspaceDefaultsStore(store: backing).remember(expected, forServer: "local")
        let reloaded = NewWorkspaceDefaultsStore(store: backing)
        #expect(reloaded.defaults(forServer: "local") == expected)
        #expect(reloaded.defaults(forServer: "remote") == nil)
    }

    @Test("Corrupt payloads reset instead of crashing")
    func corruptPayloadResets() throws {
        let backing = InMemoryStore()
        try backing.saveData(Data("not json".utf8), forKey: "new-workspace-defaults")
        let store = NewWorkspaceDefaultsStore(store: backing)
        #expect(store.defaults(forServer: "local") == nil)
    }

    @Test("clear() empties the remembered settings")
    func clears() {
        let backing = InMemoryStore()
        let store = NewWorkspaceDefaultsStore(store: backing)
        store.remember(.init(newWorktree: true), forServer: "local")
        store.clear()
        #expect(store.defaults(forServer: "local") == nil)
        #expect(NewWorkspaceDefaultsStore(store: backing).defaults(forServer: "local") == nil)
    }
}

import Foundation
import Testing
@testable import CodevisorUI

@Suite("Workspace pane preview disk store")
struct WorkspacePanePreviewDiskStoreTests {
    @Test("A preview survives store recreation and replaces atomically")
    func persistsAndReplaces() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = WorkspacePanePreviewKey(workspaceId: UUID(), paneId: UUID())

        var store: WorkspacePanePreviewDiskStore? = WorkspacePanePreviewDiskStore(
            directory: directory
        )
        try await store?.save(Data("old".utf8), for: key)
        #expect(await store?.data(for: key) == Data("old".utf8))

        store = WorkspacePanePreviewDiskStore(directory: directory)
        #expect(await store?.data(for: key) == Data("old".utf8))
        try await store?.save(Data("new".utf8), for: key)
        #expect(await store?.data(for: key) == Data("new".utf8))
    }

    @Test("Removing a pane and workspace clears only their owned previews")
    func removesOwnedPreviews() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = UUID()
        let first = WorkspacePanePreviewKey(workspaceId: workspace, paneId: UUID())
        let second = WorkspacePanePreviewKey(workspaceId: workspace, paneId: UUID())
        let other = WorkspacePanePreviewKey(workspaceId: UUID(), paneId: UUID())
        let store = WorkspacePanePreviewDiskStore(directory: directory)

        for key in [first, second, other] {
            try await store.save(Data(key.paneId.uuidString.utf8), for: key)
        }
        try await store.remove(first)
        #expect(await store.data(for: first) == nil)
        #expect(await store.data(for: second) != nil)

        try await store.removeWorkspace(workspace)
        #expect(await store.data(for: second) == nil)
        #expect(await store.data(for: other) != nil)
    }

    @Test("The least-recently-used preview is evicted at the entry limit")
    func evictsLeastRecentlyUsed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = UUID()
        let first = WorkspacePanePreviewKey(workspaceId: workspace, paneId: UUID())
        let second = WorkspacePanePreviewKey(workspaceId: workspace, paneId: UUID())
        let third = WorkspacePanePreviewKey(workspaceId: workspace, paneId: UUID())
        let store = WorkspacePanePreviewDiskStore(
            directory: directory,
            maxEntryCount: 2,
            maxByteCount: 1_024
        )

        try await store.save(Data(repeating: 1, count: 8), for: first)
        try await Task.sleep(for: .milliseconds(10))
        try await store.save(Data(repeating: 2, count: 8), for: second)
        _ = await store.data(for: first)
        try await Task.sleep(for: .milliseconds(10))
        try await store.save(Data(repeating: 3, count: 8), for: third)

        #expect(await store.data(for: first) != nil)
        #expect(await store.data(for: second) == nil)
        #expect(await store.data(for: third) != nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-pane-preview-tests-\(UUID())", isDirectory: true)
    }
}

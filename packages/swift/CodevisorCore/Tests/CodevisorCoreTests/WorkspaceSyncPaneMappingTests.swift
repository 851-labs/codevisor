import Foundation
import Testing
@testable import CodevisorCore

/// The pane<->server-record mapping behind workspace sync: plugin panes ride
/// a `plugin:`-prefixed provider with opaque metadata; unknown providers
/// still drop silently.
@MainActor
@Suite("WorkspaceSyncModel pane mapping")
struct WorkspaceSyncPaneMappingTests {
    private let workspaceId = UUID()

    @Test("Plugin panes publish a plugin-scoped provider and round-trip")
    func pluginPaneRoundTrip() {
        let id = UUID()
        let pane = PaneDescriptorState(
            id: id,
            kind: .plugin,
            name: "Git Diff",
            // Plugin panes key on their own id (there is no PTY); the
            // restored descriptor rebuilds exactly this.
            terminalKey: id.uuidString,
            pluginId: "codevisor.git-diff",
            pluginPaneType: "diff",
            pluginMetadata: PaneDescriptorState.pluginMetadataJSON(
                pluginId: "codevisor.git-diff", paneType: "diff", icon: "plus.forwardslash.minus"
            )
        )
        let record = WorkspaceSyncModel.serverPane(
            from: pane, workspaceId: workspaceId, createdAt: Date()
        )
        #expect(record.providerId == "plugin:codevisor.git-diff")
        #expect(record.paneType == "diff")
        #expect(record.title == "Git Diff")
        #expect(record.metadata == pane.pluginMetadata)
        #expect(record.resourceKind == nil)
        #expect(record.resourceId == nil)

        // The server echoes the record verbatim; the descriptor it rebuilds
        // must equal the one that was published (identical terminalKey is
        // what makes the optimistic sync barrier acknowledge the echo).
        let restored = WorkspaceSyncModel.descriptor(from: record)
        #expect(restored == pane)
        #expect(restored?.pluginIcon == "plus.forwardslash.minus")
    }

    @Test("Plugin panes without a local metadata payload synthesize one")
    func pluginPaneSynthesizesMetadata() {
        let pane = PaneDescriptorState(
            id: UUID(),
            kind: .plugin,
            name: "Diff",
            terminalKey: UUID().uuidString,
            pluginId: "codevisor.git-diff",
            pluginPaneType: "diff"
        )
        let record = WorkspaceSyncModel.serverPane(
            from: pane, workspaceId: workspaceId, createdAt: Date()
        )
        #expect(
            record.metadata
                == PaneDescriptorState.pluginMetadataJSON(
                    pluginId: "codevisor.git-diff", paneType: "diff"
                )
        )
    }

    @Test("Unknown providers and malformed plugin providers still drop silently")
    func unknownProvidersDrop() {
        func record(providerId: String, paneType: String = "diff") -> ServerWorkspacePane {
            ServerWorkspacePane(
                id: UUID().uuidString,
                workspaceId: workspaceId.uuidString,
                providerId: providerId,
                paneType: paneType,
                title: "Pane",
                createdAt: "2026-01-01T00:00:00.000Z"
            )
        }
        #expect(WorkspaceSyncModel.descriptor(from: record(providerId: "somebody-else")) == nil)
        // A bare "plugin:" carries no plugin identity.
        #expect(WorkspaceSyncModel.descriptor(from: record(providerId: "plugin:")) == nil)
        // Unknown codevisor pane types remain forward-compatible drops.
        #expect(
            WorkspaceSyncModel.descriptor(
                from: record(providerId: "codevisor", paneType: "hologram")
            ) == nil
        )
    }

    @Test("Native codevisor panes keep their existing mapping")
    func codevisorPanesStillMap() {
        let id = UUID()
        let record = ServerWorkspacePane(
            id: id.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "new-tab",
            title: "New tab",
            createdAt: "2026-01-01T00:00:00.000Z"
        )
        let descriptor = WorkspaceSyncModel.descriptor(from: record)
        #expect(descriptor?.kind == .newTab)
        #expect(descriptor?.id == id)
    }
}

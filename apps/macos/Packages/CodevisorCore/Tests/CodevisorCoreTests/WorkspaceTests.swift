import Foundation
import Testing
@testable import CodevisorCore

@Suite("Split tree")
struct SplitTreeTests {
    private func groupState(_ terminals: Int = 1) -> PaneGroupState {
        var state = PaneGroupState()
        for _ in 0..<terminals {
            state.addTerminalPane(sessionId: UUID())
        }
        return state
    }

    @Test("Codable round-trips a nested tree")
    func codableRoundTrip() throws {
        let tree = SplitNode.split(orientation: .horizontal, children: [
            SplitChild(fraction: 0.5, node: .leaf(groupState())),
            SplitChild(fraction: 0.5, node: .split(orientation: .vertical, children: [
                SplitChild(fraction: 0.3, node: .leaf(groupState(2))),
                SplitChild(fraction: 0.7, node: .leaf(groupState()))
            ]))
        ])
        let decoded = try JSONDecoder().decode(
            SplitNode.self,
            from: JSONEncoder().encode(tree)
        )
        #expect(decoded == tree)
    }

    @Test("Splitting a lone leaf wraps it in a split, new group after for trailing")
    func splitLeafTrailing() {
        let leafId = UUID()
        let newId = UUID()
        let tree = SplitNode.leaf(groupState(), id: leafId)
        let result = tree.splitting(
            groupId: leafId, edge: .trailing, newGroupId: newId, newGroupState: groupState()
        )
        guard case let .split(orientation, children) = result else {
            Issue.record("expected split")
            return
        }
        #expect(orientation == .horizontal)
        #expect(children.count == 2)
        #expect(children.map(\.fraction) == [0.5, 0.5])
        guard case let .group(firstId, _) = children[0].node,
              case let .group(secondId, _) = children[1].node else {
            Issue.record("expected group leaves")
            return
        }
        #expect(firstId == leafId)
        #expect(secondId == newId)
    }

    @Test("Splitting before with top uses vertical orientation, new group first")
    func splitLeafTop() {
        let leafId = UUID()
        let newId = UUID()
        let result = SplitNode.leaf(groupState(), id: leafId).splitting(
            groupId: leafId, edge: .top, newGroupId: newId, newGroupState: groupState()
        )
        guard case let .split(orientation, children) = result,
              case let .group(firstId, _) = children[0].node else {
            Issue.record("expected split")
            return
        }
        #expect(orientation == .vertical)
        #expect(firstId == newId)
    }

    @Test("Same-orientation split gains a sibling instead of nesting")
    func splitSameOrientationInsertsSibling() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = SplitNode.split(orientation: .horizontal, children: [
            SplitChild(fraction: 0.5, node: .leaf(groupState(), id: a)),
            SplitChild(fraction: 0.5, node: .leaf(groupState(), id: b))
        ])
        let result = tree.splitting(
            groupId: b, edge: .trailing, newGroupId: c, newGroupState: groupState()
        )
        guard case let .split(_, children) = result else {
            Issue.record("expected split")
            return
        }
        #expect(children.count == 3)
        #expect(children.map(\.fraction) == [0.5, 0.25, 0.25])
        #expect(result.allGroups.map(\.id) == [a, b, c])
    }

    @Test("Removing a group collapses single-child splits")
    func removeCollapses() {
        let a = UUID(), b = UUID()
        let tree = SplitNode.split(orientation: .horizontal, children: [
            SplitChild(fraction: 0.6, node: .leaf(groupState(), id: a)),
            SplitChild(fraction: 0.4, node: .leaf(groupState(), id: b))
        ])
        let result = tree.removingGroup(id: b)
        guard case let .group(remaining, _)? = result else {
            Issue.record("expected collapsed leaf")
            return
        }
        #expect(remaining == a)
    }

    @Test("Removing survivors renormalizes fractions")
    func removeRenormalizes() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = SplitNode.split(orientation: .horizontal, children: [
            SplitChild(fraction: 0.5, node: .leaf(groupState(), id: a)),
            SplitChild(fraction: 0.25, node: .leaf(groupState(), id: b)),
            SplitChild(fraction: 0.25, node: .leaf(groupState(), id: c))
        ])
        guard case let .split(_, children)? = tree.removingGroup(id: a) else {
            Issue.record("expected split")
            return
        }
        #expect(children.map(\.fraction) == [0.5, 0.5])
    }

    @Test("Removing the last group yields nil")
    func removeLast() {
        let a = UUID()
        #expect(SplitNode.leaf(groupState(), id: a).removingGroup(id: a) == nil)
    }

    @Test("Pruning removes empty groups and collapses their splits")
    func pruneEmptyGroups() {
        let chat = UUID(), empty = UUID(), terminal = UUID()
        // horizontal[vertical[chat | EMPTY] | terminal] — the stale shape an
        // interrupted drop leaves behind.
        let tree = SplitNode.split(orientation: .horizontal, children: [
            SplitChild(fraction: 0.5, node: .split(orientation: .vertical, children: [
                SplitChild(fraction: 0.75, node: .leaf(groupState(), id: chat)),
                SplitChild(fraction: 0.25, node: .leaf(PaneGroupState(), id: empty))
            ])),
            SplitChild(fraction: 0.5, node: .leaf(groupState(), id: terminal))
        ])
        let pruned = tree.prunedEmptyGroups
        #expect(pruned?.allGroups.map(\.id) == [chat, terminal])
        // The vertical split collapsed into the chat leaf.
        guard case let .split(orientation, children)? = pruned else {
            Issue.record("expected split")
            return
        }
        #expect(orientation == .horizontal)
        #expect(children.count == 2)
        // A tree of only empty groups prunes to nil; a healthy tree is
        // returned unchanged.
        #expect(SplitNode.leaf(PaneGroupState()).prunedEmptyGroups == nil)
        #expect(pruned?.prunedEmptyGroups == pruned)
    }

    @Test("Fraction floors protect starved children and stay proportional")
    func flooredFractions() {
        // Nothing starved: untouched.
        #expect(SplitNode.flooredFractions([0.5, 0.5], minFraction: 0.2) == [0.5, 0.5])

        // One starved child rises to the floor; the others shrink
        // proportionally (2:1 between them) and everything still sums to 1.
        let floored = SplitNode.flooredFractions([0.6, 0.3, 0.1], minFraction: 0.2)
        let expectedFirst = 8.0 / 15
        let expectedSecond = 4.0 / 15
        let flooredSum = floored.reduce(0, +)
        #expect(floored[2] == 0.2)
        #expect(abs(floored[0] - expectedFirst) < 0.0001)
        #expect(abs(floored[1] - expectedSecond) < 0.0001)
        #expect(abs(flooredSum - 1) < 0.0001)

        // Clamping can starve the next child (waterfall): both floors hold.
        let cascade = SplitNode.flooredFractions([0.7, 0.21, 0.09], minFraction: 0.25)
        #expect(cascade[1] == 0.25)
        #expect(cascade[2] == 0.25)
        #expect(abs(cascade[0] - 0.5) < 0.0001)

        // Infeasible floor (n·min > 1): equal shares.
        let equal = SplitNode.flooredFractions([0.8, 0.1, 0.1], minFraction: 0.4)
        let third = 1.0 / 3
        #expect(equal == [third, third, third])

        // Degenerate inputs pass through.
        #expect(SplitNode.flooredFractions([], minFraction: 0.2) == [])
        #expect(SplitNode.flooredFractions([0.3, 0.7], minFraction: 0) == [0.3, 0.7])
    }

    @Test("updatingGroup replaces only the target")
    func updateGroup() {
        let a = UUID(), b = UUID()
        let tree = SplitNode.split(orientation: .vertical, children: [
            SplitChild(fraction: 0.5, node: .leaf(groupState(1), id: a)),
            SplitChild(fraction: 0.5, node: .leaf(groupState(1), id: b))
        ])
        let sessionId = UUID()
        let updated = tree.updatingGroup(id: b) { state in
            var state = state
            state.addTerminalPane(sessionId: sessionId)
            return state
        }
        #expect(updated.group(id: a)?.panes.count == 1)
        #expect(updated.group(id: b)?.panes.count == 2)
    }
}

@Suite("Workspace repository")
struct WorkspaceRepositoryTests {
    private func seed(
        sessionId: UUID = UUID(),
        title: String = "Fix the tabs",
        root: String? = "/tmp/checkout"
    ) -> WorkspaceSessionSeed {
        WorkspaceSessionSeed(
            sessionId: sessionId,
            title: title,
            serverId: "local",
            projectId: UUID(),
            rootDirectory: root
        )
    }

    @Test("ensureWorkspace creates once and is idempotent")
    func ensureIdempotent() {
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let seed = seed()
        let first = repository.ensureWorkspace(for: seed, legacyGroups: nil)
        let second = repository.ensureWorkspace(for: seed, legacyGroups: nil)
        #expect(first.id == second.id)
        #expect(repository.loadAll().count == 1)
        #expect(repository.workspaceId(forSession: seed.sessionId) == first.id)
    }

    @Test("symbolName round-trips and old payloads decode without it")
    func symbolNameCodable() throws {
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        var workspace = repository.ensureWorkspace(for: seed(), legacyGroups: nil)
        // Pre-icon payloads must keep decoding (synthesized optional).
        let legacyData = try JSONEncoder().encode(workspace)
        #expect(try JSONDecoder().decode(Workspace.self, from: legacyData).symbolName == nil)
        workspace.symbolName = "hammer"
        repository.save(workspace)
        let reloaded = repository.workspace(id: workspace.id)
        #expect(reloaded?.symbolName == "hammer")
    }

    @Test("Backfill adopts the workspace's identity from the session")
    func backfillIdentity() {
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let seed = seed()
        let workspace = repository.ensureWorkspace(for: seed, legacyGroups: nil)
        #expect(workspace.name == "Fix the tabs")
        #expect(!workspace.hasCustomName)
        #expect(workspace.rootDirectory == "/tmp/checkout")
        #expect(workspace.chatSessionIds == [seed.sessionId])
        // The fresh tree is a single leaf holding the chat pane.
        #expect(workspace.centerTree.allGroups.count == 1)
        #expect(workspace.centerTree.groupId(containingChat: seed.sessionId) != nil)
        #expect(workspace.bottomGroup.panes.count == 1)
    }

    @Test("Backfill migrates legacy per-session pane groups")
    func backfillMigratesLegacyGroups() {
        let store = InMemoryStore()
        let legacy = DefaultPaneGroupRepository(store: store)
        let sessionId = UUID()
        var center = PaneGroupState.centerInitial(sessionId: sessionId)
        center.addTerminalPane(sessionId: sessionId)
        legacy.save(center, sessionId: sessionId, placement: .center)
        var bottom = PaneGroupState.initial(sessionId: sessionId)
        bottom.addTerminalPane(sessionId: sessionId)
        legacy.save(bottom, sessionId: sessionId, placement: .bottom)

        let repository = DefaultWorkspaceRepository(store: store)
        let workspace = repository.ensureWorkspace(
            for: seed(sessionId: sessionId),
            legacyGroups: legacy
        )
        // Chat + terminal in the center leaf; the chat pane learned its
        // session reference during migration.
        let centerGroup = workspace.centerTree.allGroups[0].state
        #expect(centerGroup.panes.map(\.kind) == [.chat, .terminal])
        #expect(centerGroup.panes[0].chatSessionId == sessionId)
        #expect(workspace.bottomGroup.panes.count == 2)
    }

    @Test("Automatic names track the session title until renamed")
    func nameTracking() {
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let sessionId = UUID()
        _ = repository.ensureWorkspace(for: seed(sessionId: sessionId, title: "New chat"), legacyGroups: nil)
        let retitled = repository.ensureWorkspace(
            for: seed(sessionId: sessionId, title: "Build the parser"),
            legacyGroups: nil
        )
        #expect(retitled.name == "Build the parser")

        var pinned = retitled
        pinned.name = "My workspace"
        pinned.hasCustomName = true
        repository.save(pinned)
        let after = repository.ensureWorkspace(
            for: seed(sessionId: sessionId, title: "Another title"),
            legacyGroups: nil
        )
        #expect(after.name == "My workspace")
    }

    @Test("Workspace-backed group repository round-trips both placements")
    func workspaceGroupRepository() {
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let sessionId = UUID()
        let workspace = repository.ensureWorkspace(for: seed(sessionId: sessionId), legacyGroups: nil)
        let groupId = workspace.centerTree.groupId(containingChat: sessionId)
        let bridge = WorkspacePaneGroupRepository(
            workspaceId: workspace.id,
            groupId: groupId,
            repository: repository
        )

        var center = bridge.load(sessionId: sessionId, placement: .center)
        #expect(center?.panes.first?.kind == .chat)
        center?.addTerminalPane(sessionId: sessionId)
        bridge.save(center!, sessionId: sessionId, placement: .center)
        #expect(bridge.load(sessionId: sessionId, placement: .center)?.panes.count == 2)
        #expect(repository.workspace(id: workspace.id)?.centerTree.allGroups[0].state.panes.count == 2)

        var bottom = bridge.load(sessionId: sessionId, placement: .bottom)!
        bottom.setHeight(300)
        bridge.save(bottom, sessionId: sessionId, placement: .bottom)
        #expect(repository.workspace(id: workspace.id)?.bottomGroup.height == 300)
    }

    @Test("Deleting a workspace clears its session index entries")
    func deleteClearsIndex() {
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let seed = seed()
        let workspace = repository.ensureWorkspace(for: seed, legacyGroups: nil)
        repository.delete(id: workspace.id)
        #expect(repository.loadAll().isEmpty)
        #expect(repository.workspaceId(forSession: seed.sessionId) == nil)
    }

    @Test("Persistence survives a fresh repository instance")
    func persistenceRoundTrip() {
        let store = InMemoryStore()
        let seed = seed()
        let created = DefaultWorkspaceRepository(store: store)
            .ensureWorkspace(for: seed, legacyGroups: nil)
        let reloaded = DefaultWorkspaceRepository(store: store)
        #expect(reloaded.workspace(id: created.id) == created)
        #expect(reloaded.workspaceId(forSession: seed.sessionId) == created.id)
    }

    @Test("Closed chats keep routing to their workspace (the index only grows)")
    func indexSurvivesClosedChats() {
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let seed = seed()
        var workspace = repository.ensureWorkspace(for: seed, legacyGroups: nil)

        // Close the chat's tab (its pane leaves the tree; the session is
        // archived elsewhere) — the session must still resolve to this
        // workspace, or ensureWorkspace would mint a duplicate.
        let chatGroupId = workspace.centerTree.allGroups[0].id
        workspace.centerTree = workspace.centerTree.updatingGroup(id: chatGroupId) { state in
            var state = state
            state.panes.removeAll()
            return state
        }
        repository.save(workspace)

        #expect(repository.workspaceId(forSession: seed.sessionId) == workspace.id)
        let ensured = repository.ensureWorkspace(for: seed, legacyGroups: nil)
        #expect(ensured.id == workspace.id)
        #expect(repository.loadAll().count == 1)
    }

    @Test("Loading heals empty groups left by an interrupted drop")
    func loadHealsEmptyGroups() {
        let store = InMemoryStore()
        let seed = seed()
        var workspace = DefaultWorkspaceRepository(store: store)
            .ensureWorkspace(for: seed, legacyGroups: nil)
        // Persist the stale shape directly: the chat leaf sharing a split
        // with a group that never received its pane.
        let emptyId = UUID()
        workspace.centerTree = workspace.centerTree.splitting(
            groupId: workspace.centerTree.allGroups[0].id,
            edge: .bottom,
            newGroupId: emptyId,
            newGroupState: PaneGroupState(isVisible: true)
        )
        DefaultWorkspaceRepository(store: store).save(workspace)

        let healed = DefaultWorkspaceRepository(store: store).workspace(id: workspace.id)
        #expect(healed?.centerTree.allGroups.count == 1)
        #expect(healed?.centerTree.group(id: emptyId) == nil)
    }
}

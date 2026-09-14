import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct ClientLayoutFocusTests {
  private func workspace() -> Workspace {
    let tabs = (0..<2).map { _ in
      WorkspaceTab(
        root: .split(
          orientation: .horizontal,
          children: [
            SplitChild(fraction: 0.5, node: .leaf(.centerInitial(sessionId: UUID()))),
            SplitChild(fraction: 0.5, node: .leaf(.centerInitial(sessionId: UUID()))),
          ]))
    }
    return Workspace(
      name: "Focus fixture", rootDirectory: "/fixture", serverId: "machine", projectId: UUID(),
      centerTabs: tabs, createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  private func apply(
    _ action: [String: Any], to workspace: Workspace, compact: Bool = false, focus: Bool?
  ) throws -> Workspace {
    var body: [String: Any] = ["workspaceId": workspace.id.uuidString, "action": action]
    if let focus { body["focus"] = focus }
    let data = try JSONSerialization.data(withJSONObject: body)
    return try JSONDecoder().decode(ClientLayoutRequest.self, from: data).applying(to: workspace, compact: compact)
  }

  @Test(
    "New tabs stay in the background unless focus is requested", arguments: [false, true],
    [nil, false, true] as [Bool?])
  func newTabs(compact: Bool, focus: Bool?) throws {
    var original = workspace()
    if compact {
      original.centerTabs = original.centerTabs.flatMap { tab in
        tab.root.allGroups.map { WorkspaceTab(root: .group(id: $0.id, state: $0.state)) }
      }
      original.selectedCenterTabId = original.centerTabs[0].id
    }
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    var updated = original
    // Model a batch of agent-created threads. Each committed result must
    // preserve selection; there is no follow-up navigation to restore it.
    for _ in 0..<3 {
      updated = try apply(["kind": "new_tab"], to: updated, compact: compact, focus: focus)
      repository.save(updated)
      let context = NativeClientContext.capture(
        repository: repository, serverId: "machine", workspaceId: updated.id, isActive: true)
      let surface = try #require(context.workspaces.first)
      if focus == true {
        #expect(surface.tabId == updated.centerTabs.last?.id)
        #expect(surface.paneId == updated.centerTabs.last?.root.allGroups.first?.state.selectedPaneId)
      } else {
        #expect(surface.tabId == original.selectedCenterTabId)
        #expect(surface.sessionId == original.focusedChatId(activeLeafId: nil))
      }
    }
    #expect(updated.centerTabs.count == original.centerTabs.count + 3)
    #expect(Array(updated.centerTabs.prefix(original.centerTabs.count)) == original.centerTabs)
  }

  @Test("Split, move and detach opt into selecting their result", arguments: [nil, false, true] as [Bool?])
  func layoutSelection(focus: Bool?) throws {
    let original = workspace()
    let active = original.centerTabs[0].activeLeafId
    let source = original.centerTabs[0].root.allGroups[1].id
    let target = original.centerTabs[1].activeLeafId
    let actions: [[String: Any]] = [
      ["kind": "split", "leafId": target.uuidString, "edge": "bottom"],
      ["kind": "move", "leafId": source.uuidString, "targetLeafId": target.uuidString, "edge": "bottom"],
      ["kind": "detach", "leafId": source.uuidString],
    ]
    for action in actions {
      let result = try apply(action, to: original, focus: focus)
      if focus == true {
        #expect(result.selectedCenterTabId != original.selectedCenterTabId)
        if action["kind"] as? String == "split" {
          let selected = try #require(result.selectedCenterTab)
          #expect(selected.root.group(id: selected.activeLeafId)?.selectedPane?.kind == .newTab)
        } else {
          #expect(result.selectedCenterTab?.activeLeafId == source)
        }
      } else {
        #expect(result.selectedCenterTabId == original.selectedCenterTabId)
        #expect(result.selectedCenterTab?.activeLeafId == active)
        #expect(result.focusedChatId(activeLeafId: nil) == original.focusedChatId(activeLeafId: nil))
        #expect(result.centerTabs.first(where: { $0.id == original.centerTabs[1].id })?.activeLeafId == target)
      }
    }
  }

  @Test("Background splits and same-tab moves retain the active leaf", arguments: [nil, false] as [Bool?])
  func visibleLayout(focus: Bool?) throws {
    let original = workspace()
    let active = original.centerTabs[0].activeLeafId
    let sibling = original.centerTabs[0].root.allGroups[1].id
    for action: [String: Any] in [
      ["kind": "split", "leafId": active.uuidString, "edge": "top"],
      ["kind": "move", "leafId": active.uuidString, "targetLeafId": sibling.uuidString, "edge": "bottom"],
      ["kind": "move", "leafId": sibling.uuidString, "targetLeafId": active.uuidString, "edge": "top"],
    ] {
      let result = try apply(action, to: original, focus: focus)
      #expect(result.selectedCenterTabId == original.selectedCenterTabId)
      #expect(result.selectedCenterTab?.activeLeafId == active)
      #expect(result.centerTabs[1] == original.centerTabs[1])
    }
  }

  @Test("Moving the active leaf across tabs keeps the same pane selected", arguments: [nil, false] as [Bool?])
  func movedActiveLeaf(focus: Bool?) throws {
    let original = workspace()
    let active = original.centerTabs[0].activeLeafId
    let target = original.centerTabs[1].activeLeafId
    for action: [String: Any] in [
      ["kind": "move", "leafId": active.uuidString, "targetLeafId": target.uuidString, "edge": "bottom"],
      ["kind": "detach", "leafId": active.uuidString],
    ] {
      let result = try apply(action, to: original, focus: focus)
      #expect(result.selectedCenterTab?.activeLeafId == active)
      #expect(result.focusedChatId(activeLeafId: nil) == original.focusedChatId(activeLeafId: nil))
      for tab in result.centerTabs { #expect(tab.root.group(id: tab.activeLeafId) != nil) }
    }
  }
}

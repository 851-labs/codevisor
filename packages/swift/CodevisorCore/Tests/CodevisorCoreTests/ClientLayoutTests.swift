import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct ClientLayoutTests {
  private func workspace() -> Workspace {
    Workspace(
      name: "Fixture", rootDirectory: "/fixture", serverId: "machine", projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))],
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  private func apply(_ action: [String: Any], to workspace: Workspace, compact: Bool = false) throws -> Workspace {
    let data = try JSONSerialization.data(withJSONObject: ["workspaceId": workspace.id.uuidString, "action": action])
    return try JSONDecoder().decode(ClientLayoutRequest.self, from: data).applying(to: workspace, compact: compact)
  }

  @Test("Split, resize, move and detach preserve existing pane and leaf identities")
  func layoutLifecycle() throws {
    let original = workspace()
    let first = original.centerTabs[0].activeLeafId
    var value = try apply(["kind": "split", "leafId": first.uuidString, "edge": "trailing"], to: original)
    let second = value.centerTabs[0].activeLeafId
    #expect(second != first)
    #expect(value.centerTree.group(id: first) == original.centerTree.group(id: first))
    #expect(value.centerTree.group(id: second)?.selectedPane?.kind == .newTab)
    let panes = value.centerTree.allGroups.flatMap { $0.state.panes }
    let resize: [String: Any] = [
      "kind": "resize", "tabId": value.centerTabs[0].id.uuidString, "branchPath": [],
      "fractions": [0.3, 0.7], "expectedChildren": [[first.uuidString], [second.uuidString]],
    ]
    value = try apply(resize, to: value)
    #expect(value.centerTree.clientSplit(at: [])?.children.map(\.fraction) == [0.3, 0.7])
    value = try apply(
      ["kind": "move", "leafId": second.uuidString, "targetLeafId": first.uuidString, "edge": "top"], to: value)
    #expect(value.centerTree.allGroups.map(\.id) == [second, first])
    #expect(Set(value.centerTree.allGroups.flatMap { $0.state.panes.map(\.id) }) == Set(panes.map(\.id)))
    #expect(throws: ClientControlError.self) { try apply(resize, to: value) }
    value = try apply(["kind": "detach", "leafId": second.uuidString], to: value)
    #expect(value.centerTabs.count == 2)
    #expect(value.centerTabs[0].root == original.centerTree)
    #expect(value.selectedCenterTab?.activeLeafId == second)
    #expect(try apply(["kind": "detach", "leafId": second.uuidString], to: value) == value)
    value = try apply(
      ["kind": "move", "leafId": second.uuidString, "targetLeafId": first.uuidString, "edge": "trailing"], to: value)
    #expect(value.centerTabs.count == 1)
    #expect(value.centerTree.allGroups.map(\.id) == [first, second])
    #expect(value.selectedCenterTab?.activeLeafId == second)
  }

  @Test("Nested resize targets a specific unchanged branch and preserves its siblings")
  func nestedResize() throws {
    let original = workspace()
    let first = original.centerTabs[0].activeLeafId
    let pair = try apply(["kind": "split", "leafId": first.uuidString, "edge": "trailing"], to: original)
    let second = pair.centerTabs[0].activeLeafId
    let nested = try apply(["kind": "split", "leafId": second.uuidString, "edge": "bottom"], to: pair)
    let third = nested.centerTabs[0].activeLeafId
    let action: [String: Any] = [
      "kind": "resize", "tabId": nested.centerTabs[0].id.uuidString, "branchPath": [1],
      "fractions": [0.2, 0.8], "expectedChildren": [[second.uuidString], [third.uuidString]],
    ]
    let resized = try apply(action, to: nested)
    #expect(resized.centerTree.clientSplit(at: [1])?.children.map(\.fraction) == [0.2, 0.8])
    #expect(resized.centerTree.clientSplit(at: [])?.children.map(\.fraction) == [0.5, 0.5])
    for (key, bad) in [
      ("fractions", [0.0, 1.0] as Any), ("fractions", [0.3, 0.3]), ("branchPath", [-1]), ("branchPath", [0]),
    ] {
      var invalid = action
      invalid[key] = bad
      #expect(throws: ClientControlError.self) { try apply(invalid, to: nested) }
    }
  }

  @Test("Compact clients create, reorder and rename tabs without changing content")
  func compactTabs() throws {
    let original = workspace()
    var value = try apply(["kind": "new_tab"], to: original, compact: true)
    let selected = value.selectedCenterTabId
    let ids = value.centerTabs.reversed().map { $0.id.uuidString }
    value = try apply(["kind": "reorder_tabs", "tabIds": ids], to: value, compact: true)
    #expect(value.centerTabs.map { $0.id.uuidString } == ids)
    #expect(value.selectedCenterTabId == selected)
    value = try apply(
      ["kind": "rename_tab", "tabId": selected.uuidString, "title": "  Notes  "], to: value, compact: true)
    #expect(value.selectedCenterTab?.customTitle == "Notes")
    value = try apply(["kind": "rename_tab", "tabId": selected.uuidString, "title": " "], to: value, compact: true)
    #expect(value.selectedCenterTab?.customTitle == nil)
    for action: [String: Any] in [
      ["kind": "reorder_tabs", "tabIds": [ids[0], ids[0]]],
      ["kind": "reorder_tabs", "tabIds": [ids[0]]],
      ["kind": "split", "leafId": value.centerTabs[0].activeLeafId.uuidString, "edge": "trailing"],
      ["kind": "rename_tab", "tabId": UUID().uuidString, "title": "Wrong"],
    ] {
      #expect(throws: ClientControlError.self) { try apply(action, to: value, compact: true) }
    }
  }

  @Test("Invalid changes never reach persistence")
  func validation() throws {
    let original = workspace()
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    repository.save(original)
    for action: [String: Any] in [
      ["kind": "unsupported"],
      [
        "kind": "move", "leafId": original.centerTabs[0].activeLeafId.uuidString, "targetLeafId": UUID().uuidString,
        "edge": "top",
      ],
      ["kind": "split", "leafId": UUID().uuidString, "edge": "top"],
    ] {
      #expect(throws: ClientControlError.self) { repository.save(try apply(action, to: original)) }
      #expect(repository.workspace(id: original.id) == original)
    }
    var archived = original
    archived.isArchived = true
    #expect(throws: ClientControlError.self) { try apply(["kind": "new_tab"], to: archived) }
  }

  @Test("Context describes the layout used for subsequent commands")
  func context() throws {
    let original = workspace()
    let first = original.centerTabs[0].activeLeafId
    let value = try apply(["kind": "split", "leafId": first.uuidString, "edge": "bottom"], to: original)
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    repository.save(value)
    let context = NativeClientContext.capture(
      repository: repository, serverId: "machine", workspaceId: value.id, isActive: true)
    let tab = try #require(context.workspaces.first?.tabs.first)
    #expect(tab.panes.map(\.leafId) == value.centerTree.allGroups.map { Optional($0.id) })
    #expect(tab.splits?.first?.children == value.centerTree.allGroups.map { [$0.id] })
    #expect(tab.splits?.first?.orientation == "vertical")
    #expect(tab.activeLeafId == value.centerTabs[0].activeLeafId)
    #expect(!ClientCapabilities(settingsSections: [], compact: true).windowActions.contains("frame"))
  }
}

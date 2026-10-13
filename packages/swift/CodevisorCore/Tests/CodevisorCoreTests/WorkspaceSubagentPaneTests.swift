import Foundation
import Testing
@testable import CodevisorCore

@Suite("Subagent panes")
struct WorkspaceSubagentPaneTests {
  private func pane(_ kind: PaneKind, _ name: String, toolCallId: String? = nil) -> PaneDescriptorState {
    let id = UUID()
    return PaneDescriptorState(
      id: id, kind: kind, name: name, terminalKey: id.uuidString,
      ownerChatSessionId: toolCallId == nil ? nil : UUID(), subagentToolCallId: toolCallId)
  }

  private func workspace(_ panes: PaneDescriptorState...) -> Workspace {
    Workspace(
      name: "W", rootDirectory: nil, serverId: "local", projectId: UUID(),
      centerTabs: panes.map { WorkspaceTab(root: .leaf(PaneGroupState(panes: [$0], selectedPaneId: $0.id))) },
      createdAt: Date(timeIntervalSince1970: 0))
  }

  @Test("Another agent replaces the one in the viewer split, leaving its parent chat in place")
  func replacesViewerPane() throws {
    let chat = pane(.chat, "Chat")
    let first = pane(.subagent, "First", toolCallId: "toolu_1")
    let second = pane(.subagent, "Second", toolCallId: "toolu_2")
    var state = workspace(chat)
    let opened = state.insertPane(first, besidePane: chat.id, destination: .split(.trailing))
    let viewer = try #require(opened)
    let chatLeaf = try #require(state.centerTabs[0].root.groupId(containingPane: chat.id))

    let replacement = state.replacePane(id: first.id, with: second)
    let replaced = try #require(replacement)

    #expect(replaced.tabId == viewer.tabId && replaced.leafId == viewer.leafId)
    #expect(state.centerTabs.count == 1)
    #expect(state.centerTabs[0].root.group(id: viewer.leafId)?.panes == [second])
    #expect(state.centerTabs[0].root.group(id: viewer.leafId)?.selectedPaneId == second.id)
    #expect(state.centerTabs[0].root.group(id: chatLeaf)?.panes == [chat])
    #expect(state.centerTabs[0].activeLeafId == viewer.leafId)
    #expect(state.replacePane(id: UUID(), with: pane(.subagent, "Orphan", toolCallId: "t")) == nil)
    #expect(state.replacePane(id: chat.id, with: second) == nil)
  }

  @Test("Agent panes whose chat left the workspace are removed, with any tab they emptied")
  func prunesOrphanedAgents() throws {
    let chatId = UUID()
    let chat = PaneDescriptorState(
      id: UUID(), kind: .chat, name: "Chat", terminalKey: "chat", chatSessionId: chatId)
    let kept = PaneDescriptorState(
      id: UUID(), kind: .subagent, name: "Kept", terminalKey: "kept",
      ownerChatSessionId: chatId, subagentToolCallId: "toolu_1")
    let orphan = PaneDescriptorState(
      id: UUID(), kind: .subagent, name: "Orphan", terminalKey: "orphan",
      ownerChatSessionId: UUID(), subagentToolCallId: "toolu_2")
    var state = workspace(chat, kept, orphan)

    #expect(state.pruneOrphanedSubagentPanes() == [orphan])
    #expect(state.allPanes == [chat, kept])
    #expect(state.centerTabs.count == 2)
    #expect(state.pruneOrphanedSubagentPanes().isEmpty)
  }

  @Test("A subagent pane's parent and tool call survive persistence")
  func descriptorRoundTrips() throws {
    let subagent = PaneDescriptorState(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      kind: .subagent, name: "Map the chat UI", terminalKey: "11111111-1111-1111-1111-111111111111",
      ownerChatSessionId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      subagentToolCallId: "toolu_1")
    let persisted = Data(
      """
      {"id":"11111111-1111-1111-1111-111111111111","kind":"subagent","name":"Map the chat UI","terminalKey":"11111111-1111-1111-1111-111111111111","ownerChatSessionId":"22222222-2222-2222-2222-222222222222","subagentToolCallId":"toolu_1"}
      """.utf8)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(subagent))
    let literal = try JSONSerialization.jsonObject(with: persisted)
    #expect(
      try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys])
        == JSONSerialization.data(withJSONObject: literal, options: [.sortedKeys]))
    let restored = try JSONDecoder().decode(PaneDescriptorState.self, from: persisted)
    #expect(restored == subagent)
    #expect(restored.kind.isDeviceLocal)
  }
}

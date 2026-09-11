import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct SessionAttentionWorkspaceFocusTests {
  @Test("Cached containers cannot reclaim focus after workspace navigation")
  func cachedContainerCannotReclaimFocus() {
    var focus = SessionAttentionWorkspaceFocus()
    let firstWorkspace = UUID()
    let secondWorkspace = UUID()
    let firstSource = UUID()
    let secondSource = UUID()
    let firstChat = SessionAttentionFocus(serverId: "local", sessionId: UUID())
    let secondChat = SessionAttentionFocus(serverId: "remote", sessionId: UUID())
    focus.selectWorkspace(firstWorkspace)
    focus.update(sourceId: firstSource, workspaceId: firstWorkspace, isVisible: true, session: firstChat)
    #expect(focus.session == firstChat)

    // Navigation takes effect before SwiftUI unmounts the outgoing view.
    focus.selectWorkspace(secondWorkspace)
    #expect(focus.session == nil)
    focus.update(sourceId: secondSource, workspaceId: secondWorkspace, isVisible: true, session: secondChat)
    focus.update(sourceId: firstSource, workspaceId: firstWorkspace, isVisible: true, session: firstChat)
    focus.clear(sourceId: firstSource)
    #expect(focus.session == secondChat)

    // Opening New Chat releases focus even if the old view remains cached.
    focus.selectWorkspace(nil)
    focus.update(sourceId: secondSource, workspaceId: secondWorkspace, isVisible: true, session: secondChat)
    #expect(focus.session == nil)
  }

  @Test("Hidden containers stay unread until they become visible again")
  func hiddenContainerCannotPublish() {
    var focus = SessionAttentionWorkspaceFocus()
    let workspace = UUID()
    let source = UUID()
    let chat = SessionAttentionFocus(serverId: "local", sessionId: UUID())
    focus.selectWorkspace(workspace)
    focus.update(sourceId: source, workspaceId: workspace, isVisible: false, session: chat)
    #expect(focus.session == nil)
    focus.update(sourceId: source, workspaceId: workspace, isVisible: true, session: chat)
    #expect(focus.session == chat)
    focus.update(sourceId: source, workspaceId: workspace, isVisible: false, session: chat)
    #expect(focus.session == nil)
  }

  @Test("An outgoing view cannot release a replacement view of the same chat")
  func replacementKeepsFocus() {
    var focus = SessionAttentionWorkspaceFocus()
    let workspace = UUID()
    let oldSource = UUID()
    let newSource = UUID()
    let chat = SessionAttentionFocus(serverId: "local", sessionId: UUID())
    focus.selectWorkspace(workspace)
    focus.update(sourceId: oldSource, workspaceId: workspace, isVisible: true, session: chat)
    focus.update(sourceId: newSource, workspaceId: workspace, isVisible: true, session: chat)
    focus.clear(sourceId: oldSource)
    #expect(focus.session == chat)
    focus.update(sourceId: oldSource, workspaceId: workspace, isVisible: false, session: chat)
    #expect(focus.session == chat)
    focus.update(sourceId: newSource, workspaceId: workspace, isVisible: true, session: nil)
    #expect(focus.session == nil)
  }
}

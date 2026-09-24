import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Browser pane state")
struct BrowserPaneStateTests {
  @Test func conversionAndPersistence() throws {
    let id = UUID()
    var group = PaneGroupState(
      panes: [PaneDescriptorState(id: id, kind: .newTab, name: "New Tab", terminalKey: id.uuidString)],
      selectedPaneId: id)
    let converted = group.convertNewTabPane(id: id, to: .browser, sessionId: UUID())
    let browser = try #require(converted)
    #expect(browser.kind == .browser)
    #expect(browser.browserURL == "https://www.google.com/")
    #expect(group.selectedPaneId == id)
    #expect(try JSONDecoder().decode(PaneGroupState.self, from: JSONEncoder().encode(group)) == group)
  }

  @Test func serverRoundTrip() {
    let id = UUID()
    let browser = PaneDescriptorState(
      id: id, kind: .browser, name: "Dev app", terminalKey: id.uuidString,
      browserURL: "http://localhost:3000/app?q=1#section")
    let record = WorkspaceSyncModel.serverPane(
      from: browser, workspaceId: UUID(), createdAt: Date(timeIntervalSince1970: 0))
    #expect(record.paneType == "browser")
    #expect(record.resourceKind == nil)
    #expect(record.resourceId == nil)
    #expect(record.metadata != nil)
    #expect(WorkspaceSyncModel.descriptor(from: record) == browser)
  }
}

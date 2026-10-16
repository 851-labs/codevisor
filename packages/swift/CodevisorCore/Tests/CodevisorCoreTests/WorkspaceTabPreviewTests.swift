import Foundation
import Testing
@testable import CodevisorCore

struct WorkspaceTabPreviewTests {
  @Test("Tabs saved before preview tabs existed decode as regular tabs")
  func legacyTabsAreNotPreviews() throws {
    let tab = WorkspaceTab(root: .leaf(.centerInitialWithoutChat()), isPreview: true)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
    object.removeValue(forKey: "isPreview")
    let legacy = try JSONDecoder().decode(WorkspaceTab.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(!legacy.isPreview)
    #expect(legacy.root == tab.root)
  }

  @Test("A preview tab keeps its flag through encoding")
  func previewRoundTrips() throws {
    let tab = WorkspaceTab(root: .leaf(.centerInitialWithoutChat()), isPreview: true)
    let decoded = try JSONDecoder().decode(WorkspaceTab.self, from: JSONEncoder().encode(tab))
    #expect(decoded == tab)
    #expect(decoded.isPreview)
  }
}

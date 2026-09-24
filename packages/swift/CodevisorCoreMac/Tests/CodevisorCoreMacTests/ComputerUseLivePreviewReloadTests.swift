import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use live preview refresh")
@MainActor
struct ComputerUseLivePreviewReloadTests {
  @Test("Detaches the old viewer before the new one attaches")
  func detachesFirst() {
    var events: [String] = []
    let old = ComputerUseLivePreviewViewer(title: "Finder", phase: .live) { events.append("detach old") }
    let replacement = ComputerUseLivePreview.replace(old) {
      events.append("attach new")
      return ComputerUseLivePreviewViewer(title: "Finder", phase: .live) { events.append("detach new") }
    }
    #expect(events == ["detach old", "attach new"])
    #expect(old.isDetached)
    #expect(replacement.map { !$0.isDetached } == true)
    #expect(replacement !== old)
  }

  @Test("Still detaches when no new viewer can be made")
  func detachesWithoutReplacement() {
    var detached = false
    let old = ComputerUseLivePreviewViewer(title: "Finder", phase: .live) { detached = true }
    #expect(ComputerUseLivePreview.replace(old) { nil } == nil)
    #expect(detached)
  }
}

import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
struct FileEditorSessionTests {
  private func document(_ path: String = "/file.md") -> FileDocumentModel {
    let clock = TestClock()
    return FileDocumentModel(
      path: path, sleep: { try await clock.sleep(for: $0) },
      read: { ServerFileDocument(path: path, content: "one\ntwo\nthree", version: "1", size: 13, writable: true) },
      write: { text, _ in
        ServerFileDocument(path: path, content: text, version: "2", size: text.utf8.count, writable: true)
      })
  }

  @Test(arguments: ["../src/App.swift#L8", "../src/App.swift:8:2"])
  func previewLinksRetainTheirLineWhenResolvedFromAnotherDirectory(_ link: String) throws {
    let target = try #require(FileDocumentLocation.navigationTarget(link, relativeTo: "/project/docs"))
    #expect(FileDocumentLocation.resolve(target, relativeTo: "/project") == "/project/src/App.swift")
    #expect(FileDocumentLocation.line(target) == 8)
  }

  @Test func panesShareContentButKeepIndependentPresentationAndSelection() async {
    let document = document()
    await document.refresh()
    let first = FileEditorSession(document: document)
    let second = FileEditorSession(document: document)
    first.goToLine(2)
    second.goToLine(3)
    first.preview = true
    first.showsLineNumbers = false
    first.wrapsLines = true
    #expect(first.selection.location == 4)
    #expect(second.selection.location == 8)
    #expect(!second.preview)
    #expect(second.showsLineNumbers)
    #expect(!second.wrapsLines)
    document.edit("updated contents")
    #expect(first.document.text == second.document.text)
    await document.save()
  }

  @Test func browsingBackRetainsSessionAndClosingReleasesItsNativeEditor() async {
    let document = document()
    await document.refresh()
    let sessions = FileEditorSessions { _ in document }
    weak var native: FileEditorStorage?
    weak var released: FileEditorSession?
    autoreleasepool {
      var editor: FileEditorSession? = sessions.editor(for: "/file.md")
      editor?.goToLine(2)
      native = editor?.storage
      _ = sessions.editor(for: "/other.md")
      #expect(sessions.editor(for: "/file.md") === editor)
      #expect(editor?.selection.location == 4)
      released = editor
      editor = nil
      sessions.close()
    }
    #expect(native == nil)
    #expect(released == nil)
    #expect(document.text == "one\ntwo\nthree")
  }

  @Test func cleanCacheEvictionKeepsIdentityWhileAnEditorOwnsTheDocument() {
    let store = FileDocumentStore(capacity: 1)
    let first = store.document(key: "first") { document() }
    let session = FileEditorSession(document: first)
    _ = store.document(key: "second") { document("/other.md") }
    let reopened = store.document(key: "first") {
      Issue.record("An active editor's document must be reused")
      return document()
    }
    #expect(reopened === session.document)
  }

  @Test func cacheEvictionReleasesUnownedDocumentsButPreservesUnsavedEdits() async {
    let store = FileDocumentStore(capacity: 1)
    weak var evicted = store.document(key: "clean") { document() }
    var dirty: FileDocumentModel? = store.document(key: "dirty") { document("/dirty.md") }
    #expect(evicted == nil)
    await dirty?.refresh()
    dirty?.edit("unsaved")
    weak var preserved = dirty
    dirty = nil
    _ = store.document(key: "third") { document("/third.md") }
    #expect(preserved?.text == "unsaved")
    await preserved?.save()
  }
}

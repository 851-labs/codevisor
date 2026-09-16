import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorUI
#if canImport(AppKit)
  import AppKit
#endif

private actor DocumentFixture {
  var value = ServerFileDocument(path: "/project/file.md", content: "original", version: "1", size: 8, writable: true)
  var writes: [String] = []
  private var failNext = false
  func failNextWrite() { failNext = true }
  func read() -> ServerFileDocument { value }
  func externalEdit(_ text: String) {
    value = ServerFileDocument(path: value.path, content: text, version: "2", size: text.utf8.count, writable: true)
  }
  func write(_ text: String, version: String) throws -> ServerFileDocument {
    writes.append(text)
    if failNext {
      failNext = false
      throw URLError(.notConnectedToInternet)
    }
    guard version == value.version else {
      throw CodevisorServerClientError.httpStatus(409, #"{"code":"file_conflict","error":"Changed"}"#)
    }
    value = ServerFileDocument(
      path: value.path, content: text, version: "saved-\(writes.count)", size: text.utf8.count, writable: true)
    return value
  }
}

@MainActor
struct FileDocumentModelTests {
  #if canImport(AppKit)
    @Test(arguments: [false, true])
    func resizingEditorKeepsFirstColumnBesideCompactGutter(wrapping: Bool) async {
      let clock = TestClock()
      let fixture = DocumentFixture()
      await fixture.externalEdit(String(repeating: "source ", count: 100))
      let document = FileDocumentModel(
        path: "/project/file.md", sleep: { try await clock.sleep(for: $0) }, read: { await fixture.read() },
        write: { try await fixture.write($0, version: $1) })
      await document.refresh()
      let session = FileEditorSession(document: document)
      let editor = session.storage
      editor.native.textView.setFrameSize(NSSize(width: 2000, height: 600))
      session.wrapsLines = wrapping
      editor.update(theme: .system, highlight: nil)
      for width in [1000.0, 760.0, 1000.0] {
        editor.native.container.setFrameSize(NSSize(width: width, height: 600))
        editor.native.container.layoutSubtreeIfNeeded()
        let start = editor.native.textView.convert(
          NSPoint(x: editor.native.textView.textContainerInset.width, y: 16), to: editor.native.container)
        let gutter = editor.native.container.gutter
        let gutterFrame = gutter.convert(gutter.bounds, to: editor.native.container)
        #expect(gutterFrame.width < 48)
        #expect(start.x >= gutterFrame.maxX + 8)
        #expect(start.x <= gutterFrame.maxX + 16)
        if wrapping {
          #expect(editor.native.textView.frame.width == editor.native.container.contentSize.width)
          #expect(editor.native.textView.textContainer!.size.width < width)
        }
      }
    }
  #endif

  @Test func creatingNativeEditorPreservesRequestedSelection() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    await fixture.externalEdit("first\nsecond\nthird")
    let document = FileDocumentModel(
      path: "/project/file.md", sleep: { try await clock.sleep(for: $0) }, read: { await fixture.read() },
      write: { try await fixture.write($0, version: $1) })
    await document.refresh()
    let session = FileEditorSession(document: document)
    session.goToLine(2)
    _ = session.storage
    #expect(session.selection == NSRange(location: 6, length: 0))
    #expect(session.document === document)
  }

  @Test func staleRefreshCannotUndoACompletedSave() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let readEntered = TestSignal()
    let readRelease = TestSignal()
    let draftDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let draftURL = draftDirectory.appendingPathComponent("draft.json")
    defer { try? FileManager.default.removeItem(at: draftDirectory) }
    let seed = FileDocumentModel(
      path: "/project/file.md", draftURL: draftURL, sleep: { try await clock.sleep(for: $0) },
      read: { await fixture.read() },
      write: { try await fixture.write($0, version: $1) })
    await seed.refresh()
    seed.edit("my edits")
    seed.persistDraft()
    let recovered = FileDocumentModel(
      path: "/project/file.md", draftURL: draftURL,
      sleep: { try await clock.sleep(for: $0) },
      read: {
        let value = await fixture.read()
        readEntered.signal()
        await readRelease.wait()
        return value
      }, write: { try await fixture.write($0, version: $1) })
    let refresh = Task { await recovered.refresh() }
    await readEntered.wait()
    await recovered.save()
    readRelease.signal()
    await refresh.value
    #expect(recovered.text == "my edits")
    #expect(recovered.snapshot?.content == "my edits")
    #expect(!recovered.isDirty)
  }

  @Test func typingDuringSaveAutomaticallySavesTheLatestRevision() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let entered = TestSignal()
    let release = TestSignal()
    let document = FileDocumentModel(
      path: "/project/file.md", sleep: { try await clock.sleep(for: $0) }, read: { await fixture.read() },
      write: { text, version in
        entered.signal()
        await release.wait()
        return try await fixture.write(text, version: version)
      })
    await document.refresh()
    document.edit("first edit")
    let save = Task { await document.save() }
    await entered.wait()
    document.edit("second edit")
    release.signal()
    await save.value
    #expect(await fixture.writes == ["first edit", "second edit"])
    #expect(await fixture.read().content == "second edit")
    #expect(document.text == "second edit")
    #expect(!document.isDirty)
  }

  @Test func deferredLineLinkUsesLoadedText() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    await fixture.externalEdit("one\ntwo\nthree")
    let document = FileDocumentModel(
      path: "/project/file.md", sleep: { try await clock.sleep(for: $0) }, read: { await fixture.read() },
      write: { try await fixture.write($0, version: $1) })
    let session = FileEditorSession(document: document)
    session.goToLine(3)
    await document.refresh()
    session.resolvePendingLine()
    #expect(session.selection.location == 8)
  }

  @Test func externalChangePreservesEditsUntilReviewed() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let document = FileDocumentModel(
      path: "/project/file.md", sleep: { try await clock.sleep(for: $0) }, read: { await fixture.read() },
      write: { try await fixture.write($0, version: $1) })
    await document.refresh()
    document.edit("my edits")
    await fixture.externalEdit("agent edits")
    await document.refresh()
    #expect(document.text == "my edits")
    #expect(document.conflict?.content == "agent edits")
    await document.save()
    #expect(await fixture.read().content == "agent edits")
    document.keepEdits()
    await awaitObserved { !document.isDirty && !document.isSaving }
    #expect(await fixture.read().content == "my edits")
    #expect(!document.isDirty)
  }

  @Test func detectsChangeBetweenReadAndSave() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let document = FileDocumentModel(
      path: "/project/file.md", sleep: { try await clock.sleep(for: $0) }, read: { await fixture.read() },
      write: { try await fixture.write($0, version: $1) })
    await document.refresh()
    document.edit("my edits")
    await fixture.externalEdit("other device")
    await document.save()
    #expect(document.text == "my edits")
    #expect(document.isDirty)
    #expect(document.conflict?.content == "other device")
    document.useDiskVersion()
    #expect(document.text == "other device")
    #expect(!document.isDirty)
  }

  @Test func recoversDraftAgainstItsOriginalRevision() async throws {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("draft.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = FileDocumentModel(
      path: "/project/file.md", draftURL: url, sleep: { try await clock.sleep(for: $0) },
      read: { await fixture.read() },
      write: { try await fixture.write($0, version: $1) })
    await document.refresh()
    document.edit("recovered edits")
    document.persistDraft()
    await fixture.externalEdit("external edits")
    let recovered = FileDocumentModel(
      path: "/project/file.md", draftURL: url, sleep: { try await clock.sleep(for: $0) },
      read: { await fixture.read() },
      write: { try await fixture.write($0, version: $1) })
    #expect(recovered.text == "recovered edits")
    await recovered.refresh()
    #expect(recovered.text == "recovered edits")
    #expect(recovered.conflict?.content == "external edits")
    recovered.keepEdits()
    await recovered.save()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func autosaveWaitsForAPauseInTyping() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let document = FileDocumentModel(
      path: "/project/file.md", sleep: { try await clock.sleep(for: $0) },
      read: { await fixture.read() }, write: { try await fixture.write($0, version: $1) })
    await document.refresh()
    document.edit("first edit")
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(499))
    #expect(await fixture.writes.isEmpty)
    document.edit("second edit")
    await clock.waitForSleep(.milliseconds(500), count: 2)
    clock.advance(by: .milliseconds(499))
    #expect(await fixture.writes.isEmpty)
    clock.advance(by: .milliseconds(1))
    await awaitObserved { !document.isDirty && !document.isSaving }
    #expect(await fixture.writes == ["second edit"])
  }

  @Test func leavingThePaneFlushesBeforeTheDebounceExpires() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let document = FileDocumentModel(
      path: "/project/file.md", sleep: { try await clock.sleep(for: $0) },
      read: { await fixture.read() }, write: { try await fixture.write($0, version: $1) })
    await document.refresh()
    document.edit("leaving now")
    await clock.waitForSleep(.milliseconds(500))
    document.flushAutosave()
    await awaitObserved { !document.isDirty && !document.isSaving }
    #expect(await fixture.writes == ["leaving now"])
    #expect(clock.pendingCount == 0)
  }

  @Test func failedAutosaveKeepsDraftAndRetrySavesIt() async throws {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("draft.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = FileDocumentModel(
      path: "/project/file.md", draftURL: url, sleep: { try await clock.sleep(for: $0) },
      read: { await fixture.read() }, write: { try await fixture.write($0, version: $1) })
    await document.refresh()
    await fixture.failNextWrite()
    document.edit("offline edits")
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await awaitObserved { document.error != nil && !document.isSaving }
    #expect(document.isDirty)
    #expect(await fixture.read().content == "original")
    let draft = try JSONDecoder().decode(FileDocumentModel.Draft.self, from: Data(contentsOf: url))
    #expect(draft.text == "offline edits")
    await document.refresh()
    #expect(document.error != nil)  // Reading successfully must not hide a failed save.
    await document.retry()
    #expect(await fixture.read().content == "offline edits")
    #expect(document.error == nil)
    #expect(!document.isDirty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func recoveredDraftAutosavesAfterCheckingTheMachineRevision() async {
    let clock = TestClock()
    let fixture = DocumentFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("draft.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let original = FileDocumentModel(
        path: "/project/file.md", draftURL: url, sleep: { try await clock.sleep(for: $0) },
        read: { await fixture.read() }, write: { try await fixture.write($0, version: $1) })
      await original.refresh()
      original.edit("recovered edits")
      original.persistDraft()
    }
    let recovered = FileDocumentModel(
      path: "/project/file.md", draftURL: url, sleep: { try await clock.sleep(for: $0) },
      read: { await fixture.read() }, write: { try await fixture.write($0, version: $1) })
    #expect(recovered.isDirty)
    #expect(await fixture.writes.isEmpty)
    await recovered.refresh()
    await clock.waitForSleep(.milliseconds(500))
    clock.advance(by: .milliseconds(500))
    await awaitObserved { !recovered.isDirty && !recovered.isSaving }
    #expect(await fixture.read().content == "recovered edits")
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

}

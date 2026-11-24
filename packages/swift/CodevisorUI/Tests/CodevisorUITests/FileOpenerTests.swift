import CodevisorClient
import Foundation
import Synchronization
import Testing
import TranscriptKit

@testable import CodevisorUI

@MainActor
@Suite("Opening files")
struct FileOpenerTests {
  @Test("A previewable file opens in the lightbox, paging through the previewable files beside it")
  func previewableFileOpensAmongItsSiblings() {
    let fixture = OpenerFixture()
    let shot = file("shots/before.png")
    let report = file("docs/report.pdf")
    fixture.opener.siblings = { _ in [shot, file("logs.zip"), report] }

    fixture.opener.open(report)

    #expect(fixture.lightbox.files == [shot, report])
    #expect(fixture.lightbox.current == report)
    #expect(fixture.menus.isEmpty)
  }

  @Test("A file with no useful preview offers its actions instead of opening the lightbox")
  func unpreviewableFileOffersItsMenu() {
    let fixture = OpenerFixture()

    fixture.opener.open(file("build/logs.zip"))

    #expect(!fixture.lightbox.isPresented)
    #expect(fixture.menus.map(\.title) == ["logs.zip"])
    #expect(
      fixture.menus.first?.sections.flatMap { $0 }.map(\.title) == ["Open in New Tab", "Download", "Save As…", "Copy"])
  }

  @Test("Where there are no tabs, a file offers no way to open one and still previews")
  func tablessChatsNeverOfferATab() {
    let fixture = OpenerFixture(hasTabs: false)
    let source = file("Sources/App.swift")

    fixture.opener.open(source)

    #expect(fixture.lightbox.current == source)
    #expect(!fixture.opener.canOpenInTab(source))
    #expect(
      fixture.opener.menu(for: source).sections.flatMap { $0 }.map(\.title) == [
        "Preview", "Download", "Save As…", "Copy",
      ])
  }

  @Test("A folder opens in a tab, where it can be browsed")
  func folderOpensInATab() {
    let fixture = OpenerFixture()

    fixture.opener.open(file("Sources/App/"))

    #expect(fixture.tabs == ["Sources/App/"])
    #expect(!fixture.lightbox.isPresented)
  }

  @Test("Paging wraps from the last file back to the first")
  func pagingWraps() {
    let fixture = OpenerFixture()
    let first = file("a.png")
    let last = file("b.png")
    fixture.opener.siblings = { _ in [first, last] }
    fixture.opener.open(last)

    fixture.lightbox.showNext()
    #expect(fixture.lightbox.current == first)

    fixture.lightbox.showPrevious()
    #expect(fixture.lightbox.current == last)
  }

  @Test("Opening the current file in a tab closes the lightbox and keeps the linked line")
  func openInTabClosesTheLightbox() {
    let fixture = OpenerFixture()
    let source = file("Sources/App.swift:42")
    fixture.opener.open(source)

    fixture.opener.openInNewTab(source)

    #expect(fixture.tabs == ["Sources/App.swift:42"])
    #expect(!fixture.lightbox.isPresented)
  }

  @Test("Adding the open image to the chat closes the lightbox")
  func addToChatClosesTheLightbox() throws {
    let fixture = OpenerFixture()
    var added: [PreviewFile] = []
    fixture.opener.addToChat = { added.append($0) }
    let shot = file("shots/before.png")
    fixture.opener.open(shot)
    let addToChat = try #require(fixture.opener.menu(for: shot).sections.first?.first)

    addToChat.perform()

    #expect(added.map(\.name) == ["before.png"])
    #expect(!fixture.lightbox.isPresented)
  }

  @Test("An attachment that has not been sent yet is read from this device")
  func unsentAttachmentLoadsFromThisDevice() async throws {
    let fixture = OpenerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("pasted")
    try Data("pixels".utf8).write(to: url)
    let pasted = ViewableFile(deviceFile: url, name: "Pasted Image", mimeType: "image/png")

    let item = fixture.opener.transferItem(for: pasted)

    #expect(item.name == "Pasted Image.png")
    #expect(try await item.load() == Data("pixels".utf8))
    #expect(fixture.transport.requests.isEmpty)
  }

  @Test("The lightbox shows a file read-only even when the machine would let it be edited")
  func lightboxPagesAreReadOnly() async throws {
    let fixture = OpenerFixture()
    fixture.transport.respond(
      #"{"path":"/project/notes.txt","content":"hello","version":"v1","size":5,"writable":true}"#)
    let notes = file("notes.txt")
    fixture.opener.open(notes)
    let page = try #require(fixture.lightbox.page(for: notes))

    await page.refreshDocument()

    #expect(page.document.text == "hello")
    #expect(!page.document.isEditable)
  }

  private func file(_ path: String) -> ViewableFile {
    ViewableFile(PreviewFile(serverPath: path))
  }
}

@MainActor
private final class OpenerFixture {
  let lightbox = FileLightbox()
  let transport = DocumentTransport()
  private(set) var tabs: [String] = []
  private(set) var menus: [FileMenu] = []
  var opener: FileOpener

  init(hasTabs: Bool = true) {
    let site = FileOpener.Site(
      rootPath: "/project", machineId: "machine",
      client: CodevisorServerClient(config: CodevisorServerConfig(requestTransport: transport)))
    opener = FileOpener(identity: .unique, site: site, lightbox: lightbox)
    if hasTabs {
      opener = FileOpener(identity: .unique, site: site, lightbox: lightbox) { [weak self] target in
        self?.tabs.append(target)
        return true
      }
    }
    opener.transfers = FileTransfers(download: { _ in }, saveAs: { _ in })
    opener.presentMenu = { [weak self] menu in self?.menus.append(menu) }
  }
}

private final class DocumentTransport: ServerRequestTransport, Sendable {
  private let body = Mutex<String?>(nil)
  private let sent = Mutex<[URLRequest]>([])

  var requests: [URLRequest] { sent.withLock { $0 } }

  func respond(_ body: String) {
    self.body.withLock { $0 = body }
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    sent.withLock { $0.append(request) }
    let url = try #require(request.url)
    let body = try #require(body.withLock { $0 }, "Unexpected request \(url.path)")
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
    return (Data(body.utf8), response)
  }
}

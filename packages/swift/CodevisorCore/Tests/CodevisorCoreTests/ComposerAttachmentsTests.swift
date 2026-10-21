import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("Composer attachment ownership")
struct ComposerAttachmentsTests {
  @Test("A removed placeholder discards its late staged file without uploading it")
  func removedPlaceholderDiscardsLateFile() throws {
    let files = ComposerAttachmentFileStore.temporary()
    defer { try? FileManager.default.removeItem(at: files.root) }
    var failures: [String] = []
    let attachments = ComposerAttachments(
      files: files,
      client: { nil },
      uploadLimitBytes: { MachineStatus.legacyUploadLimitBytes },
      onChange: {},
      reportFailure: { failures.append($0) },
      rememberPreview: { _, _ in }
    )
    let id = UUID()
    #expect(attachments.beginLoadingAttachment(id: id, name: "note.txt", mimeType: "text/plain", kind: .file))
    attachments.removeAttachment(id: id)
    let url = try files.stage(data: Data("late bytes".utf8), id: id, name: "note.txt")

    let failure = attachments.resolveLoadingAttachment(
      id: id, name: "note.txt", mimeType: "text/plain", kind: .file, stagedFileURL: url
    )

    #expect(failure == nil)
    #expect(attachments.items.isEmpty)
    #expect(failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("A loading attachment appears at once with its preview, blocks send, then stages its loaded file")
  func loadingAttachmentAppearsBeforeItsFile() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let started = TestSignal()
    let release = TestSignal()

    let id = try #require(
      fixture.attachments.attachLoading(name: "Photo.jpg", mimeType: "image/jpeg", kind: .image) { id, files in
        started.signal()
        await release.wait()
        let url = try files.stage(data: Data("heic bytes".utf8), id: id, name: "IMG_0001.heic")
        return LoadedAttachmentFile(fileURL: url, name: "IMG_0001.heic", mimeType: "image/heic", kind: .image)
      })

    #expect(fixture.attachments.items.map(\.id) == [id])
    #expect(fixture.attachments.items.first?.state == .loading)
    #expect(fixture.attachments.items.first?.fileURL == nil)
    await started.wait()
    fixture.attachments.showLoadingPreview(Data("picker thumbnail".utf8), for: id)
    #expect(fixture.attachments.items.first?.loadingPreviewData == Data("picker thumbnail".utf8))
    #expect(await fixture.attachments.collectAttachmentsForSend() == nil)
    #expect(fixture.failures == ["An attachment is still loading. Wait for it to finish, then send again."])

    release.signal()
    await awaitObserved { fixture.attachments.items.first?.state != .loading }

    let attachment = try #require(fixture.attachments.items.first)
    #expect(attachment.id == id)
    #expect(attachment.name == "IMG_0001.heic")
    #expect(attachment.mimeType == "image/heic")
    let fileURL = try #require(attachment.fileURL)
    #expect(try Data(contentsOf: fileURL) == Data("heic bytes".utf8))
    #expect(attachment.state == .failed("Server unavailable"))
  }

  @Test("A failed load stays on its chip and Retry loads it again")
  func failedLoadShowsOnChipAndRetries() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let attempts = TestSignal()

    let id = try #require(
      fixture.attachments.attachLoading(name: "Video.mov", mimeType: "video/quicktime", kind: .file) { id, files in
        attempts.signal()
        guard attempts.value > 1 else { throw CocoaError(.fileReadUnknown) }
        let url = try files.stage(data: Data("movie".utf8), id: id, name: "Video.mov")
        return LoadedAttachmentFile(fileURL: url, name: "Video.mov", mimeType: "video/quicktime", kind: .file)
      })
    await awaitObserved { fixture.attachments.items.first?.state != .loading }

    #expect(
      fixture.attachments.items.first?.state
        == .failed("Couldn't load “Video.mov”. Retry, or remove it and attach it again."))
    #expect(fixture.attachments.items.first?.fileURL == nil)
    #expect(fixture.failures.isEmpty)

    fixture.attachments.retryAttachment(id: id)
    #expect(fixture.attachments.items.first?.state == .loading)
    await awaitObserved { fixture.attachments.items.first?.state != .loading }

    #expect(attempts.value == 2)
    let fileURL = try #require(fixture.attachments.items.first?.fileURL)
    #expect(try Data(contentsOf: fileURL) == Data("movie".utf8))
  }

  @Test("Removing a loading attachment cancels its load")
  func removingLoadingAttachmentCancelsLoad() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let started = TestSignal()
    let cancelled = TestSignal()

    let id = try #require(
      fixture.attachments.attachLoading(name: "Video.mov", mimeType: "video/quicktime", kind: .file) { _, _ in
        await withTaskCancellationHandler {
          started.signal()
          await cancelled.wait()
        } onCancel: {
          cancelled.signal()
        }
        throw CancellationError()
      })
    await started.wait()

    fixture.attachments.removeAttachment(id: id)

    await cancelled.wait()
    #expect(fixture.attachments.items.isEmpty)
    #expect(fixture.failures.isEmpty)
  }
}

@MainActor
private final class Fixture {
  let files = ComposerAttachmentFileStore.temporary()
  var failures: [String] = []
  lazy var attachments = ComposerAttachments(
    files: files,
    client: { nil },
    uploadLimitBytes: { MachineStatus.legacyUploadLimitBytes },
    onChange: {},
    reportFailure: { [unowned self] in failures.append($0) },
    rememberPreview: { _, _ in }
  )

  func cleanUp() {
    try? FileManager.default.removeItem(at: files.root)
  }
}

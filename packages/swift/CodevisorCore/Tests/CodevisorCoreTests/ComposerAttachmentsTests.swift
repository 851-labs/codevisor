import ACPKit
import Foundation
import Testing

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
}

import Testing
import TranscriptKit
import UniformTypeIdentifiers

@testable import CodevisorUI

struct AttachmentMediaKindTests {
  @Test(arguments: [
    ("scratch/shot.png", AttachmentMediaKind.image),
    ("scratch/clip.mp4", .video),
    ("scratch/clip.mov", .video),
    ("docs/report.pdf", .pdf),
    ("notes.md", .file),
    ("archive.zzzz", .file),
  ])
  func classifiesLinkedFilesByName(path: String, kind: AttachmentMediaKind) {
    #expect(AttachmentMediaKind(file: PreviewFile(serverPath: path)) == kind)
  }

  @Test("A MIME type outranks an ambiguous name")
  func mimeTypeWins() {
    #expect(AttachmentMediaKind(name: "download", mimeType: "video/mp4", kind: .file) == .video)
    #expect(AttachmentMediaKind(name: "download", mimeType: "application/pdf", kind: .file) == .pdf)
    #expect(AttachmentMediaKind(name: "download", mimeType: "image/png", kind: .file) == .image)
    #expect(AttachmentMediaKind(name: "download", mimeType: "application/octet-stream", kind: .file) == .file)
  }

  @Test("Attachments declared as images stay images whatever their name")
  func declaredImageKindWins() {
    #expect(AttachmentMediaKind(name: "photo.bin", mimeType: "application/octet-stream", kind: .image) == .image)
  }

  @Test(arguments: [
    ("clip.mp4", "video/mp4", UTType.mpeg4Movie),
    ("report.pdf", "application/pdf", .pdf),
    ("shot.png", "image/png", .png),
    ("clip.mov", "application/octet-stream", .quickTimeMovie),
    ("blob", "application/octet-stream", .data),
  ])
  func resolvesContentTypeForCopyAndShare(name: String, mimeType: String, type: UTType) {
    #expect(attachmentContentType(name: name, mimeType: mimeType) == type)
  }
}

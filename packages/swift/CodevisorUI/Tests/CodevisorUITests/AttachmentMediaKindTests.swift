import Testing
import TranscriptKit
import UniformTypeIdentifiers

@testable import CodevisorUI

/// Copy and share must describe the attachment they act on: a video copies
/// as a video, a PDF as a PDF, and only real images copy as pictures.
struct AttachmentMediaKindTests {
  @Test(arguments: [
    ("scratch/shot.png", AttachmentMediaKind.image, "Copy Image"),
    ("scratch/clip.mp4", .video, "Copy Video"),
    ("scratch/clip.mov", .video, "Copy Video"),
    ("docs/report.pdf", .pdf, "Copy PDF"),
    ("notes.md", .file, "Copy File"),
    ("archive.zzzz", .file, "Copy File"),
  ])
  func classifiesLinkedFilesByName(path: String, kind: AttachmentMediaKind, title: String) {
    let file = PreviewFile(serverPath: path)
    #expect(AttachmentMediaKind(file: file) == kind)
    #expect(kind.copyTitle == title)
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

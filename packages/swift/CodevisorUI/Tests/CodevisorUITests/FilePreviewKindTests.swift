import Testing

@testable import CodevisorUI

@Suite("How a file previews")
struct FilePreviewKindTests {
  @Test(arguments: [
    ("shot.png", FilePreviewKind.image),
    ("diagram.svg", .image),
    ("report.pdf", .document),
    ("clip.mov", .video),
    ("clip.mp4", .video),
    ("voice.mp3", .document),
    ("App.swift", .document),
    ("Makefile", .document),
    ("Cargo.toml", .document),
    ("logs.zip", .none),
    ("backup.tar.gz", .none),
    ("Installer.dmg", .none),
  ])
  func classifiesByName(name: String, kind: FilePreviewKind) {
    #expect(FilePreviewKind(name: name) == kind)
  }

  @Test("A nameless attachment falls back to its declared type")
  func declaredTypeNamesAnExtensionlessFile() {
    #expect(FilePreviewKind(name: "Image", mimeType: "image/png") == .image)
    #expect(FilePreviewKind(name: "download", mimeType: "application/zip") == .none)
  }
}

import Testing

@testable import CodevisorUI

struct FileIconTests {
  @Test(arguments: [
    ("/remote/Sources/App.swift", "swift"),
    ("/remote/package.json", "npm"),
    ("/remote/settings.json", "json"),
    ("/remote/Dockerfile", "docker"),
    ("/remote/.gitignore", "git"),
    ("/remote/tsconfig.json", "tsconfig"),
    ("/remote/README.MD", "markdown"),
    ("/remote/button.tsx", "reactts"),
    ("/remote/models.d.ts", "typescriptdef"),
    ("/remote/editor.spec.ts", "testts"),
    ("/remote/editor.ts", "typescript"),
    ("/remote/assets/photo.png", "image"),
  ])
  func recognizesFileIdentity(path: String, icon: String) {
    #expect(FileIconCatalog.assetName(for: path) == "file_type_" + icon)
  }

  @Test(arguments: ["notes.txt", "unknown.zzzz", "Untitled", ".unknown", "/folder.swift/unknown", ""])
  func unknownAndPlainTextUseNativeDocument(path: String) {
    #expect(FileIconCatalog.assetName(for: path) == nil)
  }
}

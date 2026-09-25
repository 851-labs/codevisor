import ACPKit
import Foundation
import Testing
import UniformTypeIdentifiers
import CodevisorTestSupport
@testable import CodevisorCore

@Suite("Composer attachments")
struct ComposerAttachmentTests {
  @Test("File URL pasteboard data decodes without object coercion")
  func pasteboardFileURLDataDecoding() async throws {
    let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")
    let provider = try #require(NSItemProvider(contentsOf: expected))
    let data = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, any Error>) in
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
        data, error in
        if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: error ?? MissingRepresentationError())
        }
      }
    }

    #expect(decodePasteboardFileURL(data) == expected)
  }

  @Test("File URL pasteboard decoding rejects non-file and malformed data")
  func pasteboardFileURLDataValidation() throws {
    let remote = try #require(URL(string: "https://example.com/image.png"))

    #expect(decodePasteboardFileURL(remote.dataRepresentation) == nil)
    #expect(decodePasteboardFileURL(Data([0xFF, 0x00, 0xFF])) == nil)
  }

  @Test("File URL pasteboard decoding accepts cross-device string encodings")
  func pasteboardFileURLStringDecoding() throws {
    let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")

    #expect(decodePasteboardFileURL(Data("file:///tmp/Pasted%20Image.png\0".utf8)) == expected)
    #expect(decodePasteboardFileURL(Data("/tmp/Pasted Image.png\n".utf8)) == expected)
    #expect(
      decodePasteboardFileURL(
        try #require("file:///tmp/Pasted%20Image.png".data(using: .utf16))
      ) == expected
    )
  }

  @Test("File URL pasteboard decoding accepts an archived NSURL")
  func pasteboardArchivedFileURLDecoding() throws {
    let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: expected as NSURL,
      requiringSecureCoding: true
    )

    #expect(decodePasteboardFileURL(data) == expected)
  }

  @Test("File URL pasteboard decoding accepts property-list wrappers")
  func pasteboardPropertyListFileURLDecoding() throws {
    let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["URL": "file:///tmp/Pasted%20Image.png"],
      format: .binary,
      options: 0
    )

    #expect(decodePasteboardFileURL(data) == expected)
  }

  @MainActor
  @Test("Optimistic attachments keep their identity and are not persisted while empty")
  func optimisticAttachmentLifecycle() async throws {
    let files = ComposerAttachmentFileStore.temporary()
    defer { try? FileManager.default.removeItem(at: files.root) }
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/attachment-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      attachmentFiles: files
    )
    let id = UUID()

    #expect(
      controller.beginLoadingAttachment(
        id: id,
        name: "Pasted image.jpeg",
        mimeType: "image/jpeg",
        kind: .image
      )
    )
    #expect(controller.composerAttachments.first?.id == id)
    #expect(controller.composerAttachments.first?.state == .loading)
    #expect(controller.draftSnapshot().attachments.isEmpty)

    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let resolutionFailure = controller.resolveLoadingAttachment(
      id: id,
      name: "cat.jpeg",
      mimeType: "image/jpeg",
      kind: .image,
      data: bytes
    )
    #expect(resolutionFailure == nil)
    await awaitObserved { controller.composerAttachments.first?.state != .loading }

    let attachment = try #require(controller.composerAttachments.first)
    #expect(attachment.id == id)
    #expect(attachment.name == "cat.jpeg")
    #expect(attachment.mimeType == "image/jpeg")
    let fileURL = try #require(attachment.fileURL)
    #expect(files.relativePath(of: fileURL) != nil)
    #expect(try Data(contentsOf: fileURL) == bytes)
    #expect(attachment.state == .failed("Server unavailable"))

    controller.removeAttachment(id: id)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  /// A sparse file reports a large size without writing its bytes.
  private func sparseFile(named name: String, bytes: Int) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("attachment-limit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()
    return url
  }

  /// The controller only weakly references its machines; callers keep
  /// the returned machine controller alive.
  @MainActor
  private func controller(
    maxUploadBytes: Int?,
    files: ComposerAttachmentFileStore
  ) -> (SessionController, MachineController) {
    let machines = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    machines.connection(for: CodevisorMachine.local.id).status = MachineStatus(
      isReachable: true, label: "Local", serverId: "local", maxUploadBytes: maxUploadBytes)
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/attachment-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      machines: machines,
      attachmentFiles: files
    )
    return (controller, machines)
  }

  @MainActor
  @Test("A server that advertises no upload limit gets the 32 MB legacy limit")
  func legacyUploadLimit() async throws {
    let files = ComposerAttachmentFileStore.temporary()
    defer { try? FileManager.default.removeItem(at: files.root) }
    let (controller, machines) = controller(maxUploadBytes: nil, files: files)
    defer { withExtendedLifetime(machines) {} }
    let tooLarge = try sparseFile(named: "capture.mov", bytes: 32 * 1024 * 1024 + 1)
    defer { try? FileManager.default.removeItem(at: tooLarge.deletingLastPathComponent()) }

    await controller.attachFileURLs([tooLarge]).value

    #expect(controller.composerAttachments.isEmpty)
    #expect(
      controller.status
        == .failed("“capture.mov” is too large to upload. Choose a file smaller than 32 MB."))
  }

  @MainActor
  @Test("The machine's advertised upload limit replaces the legacy limit")
  func advertisedUploadLimit() async throws {
    let files = ComposerAttachmentFileStore.temporary()
    defer { try? FileManager.default.removeItem(at: files.root) }
    let (controller, machines) = controller(maxUploadBytes: 64 * 1024 * 1024, files: files)
    defer { withExtendedLifetime(machines) {} }
    let aboveLegacy = try sparseFile(named: "capture.mov", bytes: 32 * 1024 * 1024 + 1)
    let aboveAdvertised = try sparseFile(named: "longer.mov", bytes: 64 * 1024 * 1024 + 1)
    defer {
      try? FileManager.default.removeItem(at: aboveLegacy.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: aboveAdvertised.deletingLastPathComponent())
    }

    await controller.attachFileURLs([aboveLegacy, aboveAdvertised]).value

    let accepted = try #require(controller.composerAttachments.first)
    #expect(controller.composerAttachments.count == 1)
    #expect(accepted.name == "capture.mov")
    #expect(accepted.fileURL.flatMap(ComposerAttachmentFileStore.byteCount(of:)) == 32 * 1024 * 1024 + 1)
    #expect(
      controller.status
        == .failed("“longer.mov” is too large to upload. Choose a file smaller than 64 MB."))
  }

  @MainActor
  @Test("Pasted bytes over the machine's limit are rejected with the limit")
  func oversizedPastedBytesRejected() throws {
    let files = ComposerAttachmentFileStore.temporary()
    defer { try? FileManager.default.removeItem(at: files.root) }
    let (controller, machines) = controller(maxUploadBytes: 1024 * 1024, files: files)
    defer { withExtendedLifetime(machines) {} }
    let id = UUID()
    #expect(controller.beginLoadingAttachment(id: id, name: "shot.png", mimeType: "image/png", kind: .image))

    let failure = controller.resolveLoadingAttachment(
      id: id, name: "shot.png", mimeType: "image/png", kind: .image,
      data: Data(count: 1024 * 1024 + 1))

    #expect(failure == "“shot.png” is too large to upload. Choose a file smaller than 1 MB.")
    #expect(controller.composerAttachments.isEmpty)
  }

  @MainActor
  @Test("File URL attachments appear synchronously while their bytes load")
  func fileURLAttachmentAppearsSynchronously() throws {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/attachment-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    let url = URL(fileURLWithPath: "/tmp/optimistic-image.png")

    controller.attachFileURLs([url])

    let attachment = try #require(controller.composerAttachments.first)
    #expect(attachment.name == "optimistic-image.png")
    #expect(attachment.kind == .image)
    #expect(attachment.fileURL == nil)
    #expect(attachment.state == .loading)
  }

  @MainActor
  @Test("Discarding an unreadable paste stays local to the composer")
  func discardedPasteDoesNotBecomeSessionFailure() {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/attachment-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    let id = UUID()
    #expect(
      controller.beginLoadingAttachment(
        id: id,
        name: "Pasted image.jpeg",
        mimeType: "image/jpeg",
        kind: .image
      )
    )

    #expect(controller.discardLoadingAttachment(id: id))
    #expect(controller.composerAttachments.isEmpty)
    #expect(controller.status == .idle)
  }

  private struct MissingRepresentationError: Error {}
}

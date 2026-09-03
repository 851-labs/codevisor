import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// Server file ids are minted per machine. These cover the composer keeping
/// its staged attachments sendable when the draft's target machine changes.
@MainActor
@Suite("Composer attachments across machine retarget")
struct ComposerAttachmentRetargetTests {
  @Test("Switching machines re-uploads staged attachments to the new machine")
  func crossMachineRetargetReuploads() async throws {
    let machineA = UploadRecordingClient(prefix: "a")
    let machineB = UploadRecordingClient(prefix: "b")
    let controller = makeController(serverId: "machine-a", client: machineA.client)

    controller.attachImageData(Data([0x89, 0x50, 0x4E, 0x47]), suggestedName: "shot.png")
    await controller.awaitUploads()
    #expect(uploadedFileIds(controller) == ["a:shot.png"])

    await controller.retarget(
      to: project(serverId: "machine-b"),
      serverClient: machineB.client
    )
    let sent = await controller.collectAttachmentsForSend()

    #expect(sent?.map(\.fileId) == ["b:shot.png"])
    #expect(machineA.uploadedNames == ["shot.png"])
    #expect(machineB.uploadedNames == ["shot.png"])
  }

  @Test("Switching projects on the same machine keeps existing uploads")
  func sameMachineRetargetKeepsUploads() async throws {
    let machineA = UploadRecordingClient(prefix: "a")
    let controller = makeController(serverId: "machine-a", client: machineA.client)

    controller.attachImageData(Data([0x89, 0x50, 0x4E, 0x47]), suggestedName: "shot.png")
    await controller.awaitUploads()

    await controller.retarget(
      to: project(serverId: "machine-a", folder: "other-project"),
      serverClient: machineA.client
    )
    let sent = await controller.collectAttachmentsForSend()

    #expect(sent?.map(\.fileId) == ["a:shot.png"])
    #expect(machineA.uploadedNames == ["shot.png"])
  }

  @Test("An upload still in flight to the old machine cannot clobber the new machine's ref")
  func inFlightOldMachineUploadIsSuperseded() async throws {
    let gate = FetchGate()
    let machineA = UploadRecordingClient(prefix: "a", beforeReturning: { await gate.wait() })
    let machineB = UploadRecordingClient(prefix: "b")
    let controller = makeController(serverId: "machine-a", client: machineA.client)

    controller.attachImageData(Data([0x89, 0x50, 0x4E, 0x47]), suggestedName: "shot.png")
    await gate.awaitWaiter()

    await controller.retarget(
      to: project(serverId: "machine-b"),
      serverClient: machineB.client
    )
    await gate.release()
    let sent = await controller.collectAttachmentsForSend()

    #expect(sent?.map(\.fileId) == ["b:shot.png"])
    #expect(uploadedFileIds(controller) == ["b:shot.png"])
  }

  @Test("Placeholders still loading their bytes are left for their own upload")
  func loadingPlaceholderIsNotReuploaded() async throws {
    let machineA = UploadRecordingClient(prefix: "a")
    let machineB = UploadRecordingClient(prefix: "b")
    let controller = makeController(serverId: "machine-a", client: machineA.client)

    let id = UUID()
    controller.beginLoadingAttachment(id: id, name: "drop.png", mimeType: "image/png", kind: .image)

    await controller.retarget(
      to: project(serverId: "machine-b"),
      serverClient: machineB.client
    )
    #expect(controller.composerAttachments.first?.state == .loading)
    #expect(machineA.uploadedNames.isEmpty)
    #expect(machineB.uploadedNames.isEmpty)

    controller.resolveLoadingAttachment(
      id: id, name: "drop.png", mimeType: "image/png", kind: .image,
      data: Data([0x89, 0x50, 0x4E, 0x47])
    )
    let sent = await controller.collectAttachmentsForSend()

    #expect(sent?.map(\.fileId) == ["b:drop.png"])
    #expect(machineA.uploadedNames.isEmpty)
  }

  // MARK: - Helpers

  private func makeController(
    serverId: String, client: SyncFakeServerClient
  ) -> SessionController {
    SessionController(
      project: project(serverId: serverId),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: ComposerDefaultsStore(store: InMemoryStore()),
      serverClient: client
    )
  }

  private func project(serverId: String, folder: String = "project") -> Project {
    Project.fromFolder(
      URL(fileURLWithPath: "/tmp/\(serverId)/\(folder)"),
      serverId: serverId
    )
  }

  private func uploadedFileIds(_ controller: SessionController) -> [String] {
    controller.composerAttachments.compactMap {
      if case let .uploaded(ref) = $0.state { return ref.fileId }
      return nil
    }
  }
}

/// A fake machine that mints file ids as `<prefix>:<name>` so a test can tell
/// which machine an attachment ref came from.
private final class UploadRecordingClient: @unchecked Sendable {
  let client: SyncFakeServerClient
  private let lock = NSLock()
  private var _uploadedNames: [String] = []

  var uploadedNames: [String] { lock.withLock { _uploadedNames } }

  init(prefix: String, beforeReturning: (@Sendable () async -> Void)? = nil) {
    client = SyncFakeServerClient(projects: [], sessions: [])
    client.capabilitiesHandler = { _ in ServerCapabilities(harnesses: []) }
    client.uploadFileHandler = { [weak self] name, mimeType, data in
      await beforeReturning?()
      self?.lock.withLock { self?._uploadedNames.append(name) }
      return try Self.metadata(id: "\(prefix):\(name)", name: name, mimeType: mimeType, size: data.count)
    }
  }

  private static func metadata(
    id: String, name: String, mimeType: String, size: Int
  ) throws -> ServerFileMetadata {
    let json = """
      {"id":"\(id)","name":"\(name)","mimeType":"\(mimeType)","sizeBytes":\(size),
       "sha256":"deadbeef","kind":"image","createdAt":"2026-01-01T00:00:00Z"}
      """
    return try JSONDecoder().decode(ServerFileMetadata.self, from: Data(json.utf8))
  }
}

extension SessionController {
  fileprivate func awaitUploads() async {
    for task in uploadTasks.values { await task.value }
  }
}

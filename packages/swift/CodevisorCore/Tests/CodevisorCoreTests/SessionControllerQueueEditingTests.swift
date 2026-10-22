import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Editing a queued message in the composer")
struct SessionControllerQueueEditingTests {
  private static let photo = ServerAttachmentRef(
    fileId: "file-photo", name: "photo.png", mimeType: "image/png", sizeBytes: 10, kind: .image)

  @Test("Editing pulls the message and its attachments into the composer, and cancelling restores the draft")
  func cancelRestoresDraft() {
    let (controller, _) = Self.controllerWithQueuedPhoto()
    controller.composerText = "half-written thought"

    controller.beginEditingQueuedPrompt(controller.queuedPrompts[0])

    #expect(controller.isEditingQueuedPrompt)
    #expect(controller.composerText == "look at this")
    #expect(controller.composerAttachments.map(\.name) == ["photo.png"])

    controller.cancelEditingQueuedPrompt()

    #expect(!controller.isEditingQueuedPrompt)
    #expect(controller.composerText == "half-written thought")
    #expect(controller.composerAttachments.isEmpty)
  }

  @Test("Saving updates the queued message's text and attachments, then restores the draft")
  func saveUpdatesQueuedMessage() async {
    let (controller, client) = Self.controllerWithQueuedPhoto()
    controller.composerText = "half-written thought"
    controller.beginEditingQueuedPrompt(controller.queuedPrompts[0])
    controller.composerText = "look at this one instead"

    #expect(await controller.saveEditedQueuedPrompt())

    #expect(client.queueUpdates.map(\.text) == ["look at this one instead"])
    #expect(client.queueUpdates.first?.attachments == [Self.photo])
    #expect(!controller.isEditingQueuedPrompt)
    #expect(controller.composerText == "half-written thought")
  }

  @Test("Removing the message being edited ends the edit and restores the draft")
  func removingEditedMessageRestoresDraft() async {
    let (controller, client) = Self.controllerWithQueuedPhoto()
    controller.composerText = "half-written thought"
    controller.beginEditingQueuedPrompt(controller.queuedPrompts[0])

    #expect(await controller.deleteQueuedPrompt(id: "queue-1"))

    #expect(client.queueDeletes == ["queue-1"])
    #expect(!controller.isEditingQueuedPrompt)
    #expect(controller.composerText == "half-written thought")
    #expect(controller.composerAttachments.isEmpty)
  }

  private static func controllerWithQueuedPhoto() -> (SessionController, FakeSessionServerClient) {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    model.promptQueue.apply([
      ServerPromptQueueItem(
        id: "queue-1", sessionId: sessionId.uuidString, text: "look at this",
        createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-20T00:00:00.000Z",
        attachments: [photo])
    ])
    return (SessionController.preview(model: model), client)
  }
}

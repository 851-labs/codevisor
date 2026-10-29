import ACPKit
import CodevisorTestSupport
import Foundation
import Observation
import Testing
import TranscriptKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("A bot send shows at once, gets its progress bar after a second, and goes out once the bot is ready")
  func botSendWaitsForTheBotToBeReady() async {
    let fixture = await BotSendFixture.make(using: loadedBotModel)
    fixture.readiness.state = .waiting("Connecting…")
    let message = UserMessage(text: "are you there?")

    fixture.queue.enqueue(message, attachmentIDs: [], route: .bot(afterSequence: 1))

    #expect(fixture.shownDeliveries == [nil])
    await fixture.clock.waitForSleep(SendQueue.progressDelay)
    fixture.clock.advance(by: SendQueue.progressDelay)
    await settleUntil { fixture.shownDeliveries == [.sending] }
    await fixture.clock.waitForSleep(SendQueue.readinessTimeout)
    #expect(fixture.client.promptedTexts.isEmpty)

    fixture.readiness.state = .ready
    await fixture.client.promptRequests.wait()
    #expect(fixture.client.promptedMessageIds == [message.id.uuidString.lowercased()])
    await settleUntil { fixture.queue.unsentBotMessages.isEmpty }
    fixture.model.shutdown()
  }

  @Test("Bot sends that wait too long for the bot all end as Not Delivered with the reason")
  func botSendsFailWhenTheBotNeverBecomesReady() async {
    let fixture = await BotSendFixture.make(using: loadedBotModel)
    fixture.readiness.state = .waiting("Dylan’s Mac is offline.")

    fixture.queue.enqueue(UserMessage(text: "first"), attachmentIDs: [], route: .bot(afterSequence: 1))
    fixture.queue.enqueue(UserMessage(text: "second"), attachmentIDs: [], route: .bot(afterSequence: 1))
    await fixture.clock.waitForSleep(SendQueue.readinessTimeout)
    fixture.clock.advance(by: SendQueue.readinessTimeout)

    let failed = TranscriptDelivery.failed(reason: "Dylan’s Mac is offline.")
    await settleUntil { fixture.shownDeliveries == [failed, failed] }
    #expect(fixture.client.promptedTexts.isEmpty)
    fixture.model.shutdown()
  }

  @Test("A bot send that can't start shows the reason, and Try Again sends it once the bot can")
  func botSendRetriesAfterAConnectionFailure() async {
    let fixture = await BotSendFixture.make(using: loadedBotModel)
    fixture.connection = .failed("Pick a model for this bot in its settings, then try again.")
    let message = UserMessage(text: "hello")

    fixture.queue.enqueue(message, attachmentIDs: [], route: .bot(afterSequence: 1))

    await settleUntil {
      fixture.shownDeliveries == [.failed(reason: "Pick a model for this bot in its settings, then try again.")]
    }
    fixture.connection = .ready(fixture.model)
    fixture.queue.retry(message.id)
    await fixture.client.promptRequests.wait()
    #expect(fixture.client.promptedMessageIds == [message.id.uuidString.lowercased()])
    fixture.model.shutdown()
  }

  @Test("A photo still uploading shows in the bubble at once and is sent with its uploaded file")
  func botSendWaitsForItsUpload() async throws {
    let fixture = await BotSendFixture.make(using: loadedBotModel)
    let photo = try fixture.uploadingPhoto()
    let message = UserMessage(text: "look", attachments: [photo.sentAttachment])

    fixture.queue.enqueue(message, attachmentIDs: [photo.id], route: .bot(afterSequence: 1))

    #expect(fixture.queue.unsentBotMessages.first?.message.attachments.map(\.fileId) == [photo.pendingFileID])
    let ref = ServerAttachmentRef(
      fileId: "file-1", name: photo.name, mimeType: photo.mimeType, sizeBytes: 3, kind: .image)
    fixture.attachments.setAttachmentState(photo.id, .uploaded(ref))
    await fixture.client.promptRequests.wait()
    #expect(fixture.client.promptedAttachments == [[ref]])
    #expect(fixture.uploads.map(\.sentFileID) == [photo.pendingFileID])
    #expect(fixture.uploads.map(\.uploaded) == [ref.attachment])
    fixture.model.shutdown()
  }

  @Test("A photo that fails to upload makes the send Not Delivered with the reason")
  func botSendFailsWhenItsUploadFails() async throws {
    let fixture = await BotSendFixture.make(using: loadedBotModel)
    let photo = try fixture.uploadingPhoto()

    fixture.queue.enqueue(
      UserMessage(text: "look", attachments: [photo.sentAttachment]), attachmentIDs: [photo.id],
      route: .bot(afterSequence: 1))
    fixture.attachments.setAttachmentState(photo.id, .failed("The disk is full."))

    await settleUntil {
      fixture.shownDeliveries == [.failed(reason: "Couldn’t upload “photo.jpg”. The disk is full.")]
    }
    #expect(fixture.client.promptedTexts.isEmpty)
    fixture.model.shutdown()
  }
}

@MainActor
@Observable
private final class BotReadinessState {
  var state = SendQueue.Readiness.ready
}

@MainActor
private final class BotSendFixture {
  let files = ComposerAttachmentFileStore.temporary()
  let clock = TestClock()
  let readiness = BotReadinessState()
  let client: FakeSessionServerClient
  let model: SessionModel
  var connection: SendQueue.Preparation
  var uploads: [(uploaded: TranscriptKit.Attachment, sentFileID: String)] = []

  lazy var attachments = ComposerAttachments(
    files: files,
    client: { nil },
    uploadLimitBytes: { MachineStatus.legacyUploadLimitBytes },
    onChange: {},
    reportFailure: { _ in },
    rememberPreview: { _, _ in }
  )

  lazy var queue = SendQueue(
    attachments: attachments,
    clock: clock,
    readiness: { [unowned self] in readiness.state },
    connect: { [unowned self] _ in connection },
    deliver: { message, _, model in await model.sendBotMessage(message, afterSequence: 1) },
    onUploaded: { [unowned self] uploaded, sentFileID in uploads.append((uploaded, sentFileID)) },
    onChange: {}
  )

  private init(client: FakeSessionServerClient, model: SessionModel) {
    self.client = client
    self.model = model
    connection = .ready(model)
  }

  static func make(
    using loadedBotModel: () async -> (FakeSessionServerClient, SessionModel)
  ) async -> BotSendFixture {
    let (client, model) = await loadedBotModel()
    return BotSendFixture(client: client, model: model)
  }

  var shownDeliveries: [TranscriptDelivery?] {
    queue.unsentBotMessages.map(\.message.delivery)
  }

  func uploadingPhoto() throws -> ComposerAttachment {
    let id = UUID()
    let url = try files.stage(data: Data("jpg".utf8), id: id, name: "photo.jpg")
    attachments.restore([
      ComposerAttachment(
        id: id, name: "photo.jpg", mimeType: "image/jpeg", kind: .image, fileURL: url, state: .uploading)
    ])
    return try #require(attachments.detachForSend().first)
  }

  isolated deinit {
    try? FileManager.default.removeItem(at: files.root)
  }
}

import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Optimistic New Chat submission")
struct SessionControllerFirstSendTests {
  @Test("First send opens the chat and owns its animation before connecting")
  func transitionsBeforeConnection() async throws {
    let fixture = try Fixture()
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    fixture.client.openSessionGate = gate
    defer { release.finish() }
    fixture.controller.promptClientId = "window-1"
    let send = Task { await fixture.controller.send() }
    await fixture.client.openSessionRequests.wait()

    #expect(fixture.promotions == 1)
    #expect(fixture.controller.hasAcceptedFirstSend)
    #expect(fixture.controller.composerText.isEmpty)
    #expect(!fixture.controller.isSubmitting)
    #expect(fixture.client.promptedTexts.isEmpty)
    let message = try #require(fixture.controller.pendingUserMessage)
    let animation = try #require(fixture.controller.userSendAnimationRequest)
    #expect(message.text == "Send this message")
    #expect(animation.messageID == message.id)

    release.finish()
    await send.value
    await fixture.client.promptRequests.wait()

    #expect(fixture.promotions == 1)
    #expect(fixture.client.promptedMessageIds == [message.id.uuidString.lowercased()])
    #expect(fixture.client.promptedClientIds == ["window-1"])
    #expect(fixture.controller.userSendAnimationRequest == animation)
    fixture.controller.model?.shutdown()
  }

  @Test("A delayed acknowledgement never holds the composer or replays promotion")
  func transitionsBeforeAcknowledgement() async throws {
    let fixture = try Fixture()
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    fixture.client.holdPrompts(until: gate)
    defer { release.finish() }
    let send = Task { await fixture.controller.send() }
    await fixture.client.promptRequests.wait()

    #expect(fixture.promotions == 1)
    #expect(fixture.controller.model != nil)
    #expect(fixture.controller.composerText.isEmpty)
    #expect(!fixture.controller.isSubmitting)
    #expect(fixture.controller.isSending)
    let animation = try #require(fixture.controller.userSendAnimationRequest)
    #expect(userMessages(in: fixture.controller).map(\.text) == ["Send this message"])
    await fixture.controller.send()
    #expect(fixture.client.promptedTexts == ["Send this message"])

    release.finish()
    await send.value

    #expect(fixture.promotions == 1)
    #expect(fixture.controller.userSendAnimationRequest == animation)
    #expect(userMessages(in: fixture.controller).count == 1)
    fixture.controller.model?.shutdown()
  }

  @Test("A send the server refuses stays in the chat as Not Delivered with its attachments")
  func failedSubmissionRemainsInChat() async throws {
    let fixture = try Fixture()
    let staged = try attachment(in: fixture.controller.attachmentFiles)
    fixture.controller.attachments.restore([staged])
    fixture.client.promptFailure = .httpStatus(422, "Please retry")

    await fixture.controller.send()
    let message = try #require(fixture.controller.transcriptProjectionInput.pendingUserMessage)
    await awaitObserved {
      fixture.controller.transcriptProjectionInput.deliveries[message.id]
        == .failed(reason: SessionModel.undeliveredReason)
    }

    #expect(fixture.promotions == 1)
    #expect(fixture.controller.hasAcceptedFirstSend)
    #expect(!fixture.controller.shouldShowNewChatComposer)
    #expect(fixture.controller.composerText.isEmpty)
    #expect(fixture.controller.composerAttachments.isEmpty)
    #expect(fixture.controller.model?.errorMessage == nil)
    #expect(fixture.controller.transcriptProjectionInput.pendingUserMessage?.attachments.map(\.name) == ["note.txt"])
    #expect(message.text == "Send this message")
    #expect(userMessages(in: fixture.controller).isEmpty)
    fixture.controller.model?.shutdown()
  }

  @Test(
    "The composer is free while a message is still being delivered, in bot and normal chats",
    .timeLimit(.minutes(1)), arguments: [true, false])
  func sendDoesNotHoldTheComposer(bot: Bool) async throws {
    let fixture = try Fixture()
    if bot { fixture.controller.presentBot(as: .conversation) }
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    fixture.client.holdPrompts(until: gate)
    defer { release.finish() }

    await fixture.controller.send()
    await fixture.client.promptRequests.wait()

    #expect(fixture.controller.composerText.isEmpty)
    #expect(!fixture.controller.isSubmitting)
    fixture.controller.composerText = "and one more"
    #expect(fixture.controller.canSend)
    fixture.controller.model?.shutdown()
  }

  @Test("A setup failure keeps the new chat open with the message Not Delivered, and Try Again sets it up again")
  func setupFailureKeepsTheChat() async throws {
    let fixture = try Fixture()
    let staged = try attachment(in: fixture.controller.attachmentFiles)
    fixture.controller.attachments.restore([staged])
    fixture.client.openSessionFailure = .httpStatus(503, "Setup failed")
    var didFailSetup = false
    fixture.controller.onSetupFailed = { didFailSetup = true }

    await fixture.controller.send()
    let message = try #require(fixture.controller.transcriptProjectionInput.pendingUserMessage)
    await awaitObserved { fixture.controller.transcriptProjectionInput.deliveries[message.id]?.isFailed == true }

    #expect(fixture.promotions == 1)
    #expect(!didFailSetup)
    #expect(fixture.controller.hasAcceptedFirstSend)
    #expect(!fixture.controller.shouldShowNewChatComposer)
    #expect(fixture.controller.status == .idle)
    #expect(fixture.controller.composerText.isEmpty)
    #expect(fixture.controller.composerAttachments.isEmpty)
    #expect(message.attachments.map(\.name) == ["note.txt"])
    #expect(FileManager.default.fileExists(atPath: try #require(staged.fileURL).path))
    #expect(fixture.controller.model == nil)
    #expect(fixture.client.promptedTexts.isEmpty)

    fixture.client.openSessionFailure = nil
    await fixture.controller.retryUnsentMessage(id: message.id)
    await fixture.client.promptRequests.wait()

    #expect(fixture.client.promptedMessageIds == [message.id.uuidString.lowercased()])
    #expect(fixture.promotions == 1)
    fixture.controller.model?.shutdown()
  }

  @Test("An early assistant response uses the already-promoted chat")
  func responseBeforeAcknowledgement() async throws {
    let fixture = try Fixture()
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    fixture.client.holdPrompts(until: gate)
    defer { release.finish() }
    let send = Task { await fixture.controller.send() }
    await fixture.client.promptRequests.wait()
    fixture.client.emit(
      ServerEventEnvelope(
        id: 1, serverId: "local", kind: "session.output",
        subjectId: fixture.sessionID.uuidString, createdAt: "2026-09-08T17:46:00Z",
        payload: .object(["role": .string("assistant"), "text": .string("Already responding")])
      ))
    await fixture.client.eventReads.wait()
    await awaitObserved {
      fixture.controller.conversation.contains { item in
        if case let .assistant(message) = item {
          return message.turn.entries.contains { entry in
            if case let .text(_, markdown) = entry { return markdown == "Already responding" }
            return false
          }
        }
        return false
      }
    }
    #expect(fixture.promotions == 1)
    #expect(fixture.controller.model != nil)
    #expect(
      fixture.controller.conversation.contains { item in
        if case let .assistant(message) = item {
          return message.turn.entries.contains { entry in
            if case let .text(_, markdown) = entry { return markdown == "Already responding" }
            return false
          }
        }
        return false
      })

    release.finish()
    await send.value

    #expect(fixture.promotions == 1)
    fixture.controller.model?.shutdown()
  }

  @Test("Opening history retains draft selections without waking the provider; send applies them in order")
  func openingDefersRuntimeMutationsUntilSend() async throws {
    let fixture = try Fixture()
    let controller = fixture.controller
    controller.serverSession = ChatSession(
      id: fixture.sessionID, projectId: controller.project.id,
      serverId: controller.project.serverId, harnessId: "codex",
      title: "Existing chat", createdAt: Date(timeIntervalSince1970: 0)
    )
    controller.configOptionsByHarness["codex"] = [
      SessionConfigOption(
        id: "model", name: "Model", category: "model", currentValue: "old",
        options: [SessionConfigSelectOption(value: "new", name: "New")]
      ),
      SessionConfigOption(
        id: "effort", name: "Effort", category: "thought_level", currentValue: "low",
        options: [SessionConfigSelectOption(value: "high", name: "High")]
      ),
      SessionConfigOption(
        id: "speed", name: "Speed", category: "speed", currentValue: "standard",
        options: [SessionConfigSelectOption(value: "fast", name: "Fast")]
      ),
    ]
    controller.pendingConfiguration.replaceValues(["speed": "fast", "effort": "high", "model": "new"], for: "codex")
    controller.pendingConfiguration.setMode("plan")
    controller.model = try await controller.connect(harnessId: "codex")
    defer { controller.model?.shutdown() }

    #expect(fixture.client.runtimeRequests.isEmpty)
    #expect(controller.modelOption?.currentValue == "new")
    #expect(controller.pendingConfiguration.modeId == "plan")
    await controller.send()
    await fixture.client.promptRequests.wait()
    #expect(
      fixture.client.runtimeRequests == [
        "mode:plan", "config:model:new", "config:effort:high", "config:speed:fast", "prompt",
      ])
    #expect(controller.pendingConfiguration.values(for: "codex") == nil)
    #expect(controller.pendingConfiguration.modeId == nil)
  }

  private func userMessages(in controller: SessionController) -> [UserMessage] {
    controller.conversation.compactMap { item in
      if case let .user(message) = item { return message }
      return nil
    }
  }

  private func attachment(in files: ComposerAttachmentFileStore) throws -> ComposerAttachment {
    let id = UUID()
    return ComposerAttachment(
      id: id, name: "note.txt", mimeType: "text/plain", kind: .file,
      fileURL: try files.stage(data: Data("note".utf8), id: id, name: "note.txt"),
      state: .uploaded(
        ServerAttachmentRef(
          fileId: "file-1", name: "note.txt", mimeType: "text/plain", sizeBytes: 4, kind: .file
        ))
    )
  }

  @MainActor
  private final class Fixture {
    let sessionID = UUID()
    let client: FakeSessionServerClient
    let controller: SessionController
    var promotions = 0

    init() throws {
      let project = Project.fromFolder(URL(fileURLWithPath: "/fixture/project"))
      client = FakeSessionServerClient(sessionId: sessionID)
      client.echoOnPrompt = false
      client.openSessionResponse = try JSONDecoder().decode(
        ServerSessionOpenResponse.self,
        from: JSONSerialization.data(withJSONObject: [
          "session": [
            "id": sessionID.uuidString, "projectId": project.id.uuidString,
            "serverId": "local", "harnessId": "codex", "title": "Draft",
            "origin": "codevisor", "createdAt": "2026-09-08T17:45:00Z",
          ],
          "transcript": [
            "items": [], "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false,
            "eventCursor": 0,
          ],
        ])
      )
      controller = SessionController(
        project: project, configCache: ConfigOptionCache(store: InMemoryStore()), serverClient: client
      )
      controller.harnesses = [
        ServerHarness(
          id: "codex", name: "Codex", symbolName: "sparkle", source: "registry",
          launchKind: "executable", enabled: true, readiness: ServerHarnessReadiness(state: "ready")
        )
      ]
      controller.selectedHarnessId = "codex"
      controller.configurationValidationState = .ready
      controller.composerText = "Send this message"
      controller.onFirstSend = { [unowned self] text in
        promotions += 1
        #expect(controller.composerText.isEmpty)
        let botMessage = controller.transcriptProjectionInput.botConversation?.messages.last
        #expect((controller.pendingUserMessage?.text ?? botMessage?.text) == text)
        #expect(controller.userSendAnimationRequest != nil)
        controller.serverSession = ChatSession(
          id: sessionID, projectId: project.id, serverId: project.serverId,
          harnessId: "codex", title: text, createdAt: Date(timeIntervalSince1970: 0)
        )
      }
    }
  }
}

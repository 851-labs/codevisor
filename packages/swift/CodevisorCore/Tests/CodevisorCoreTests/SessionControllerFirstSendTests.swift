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
    #expect(animation.destination == .optimistic)

    release.finish()
    await send.value

    #expect(fixture.promotions == 1)
    #expect(fixture.client.promptedMessageIds == [message.id.uuidString.lowercased()])
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

  @Test("Submission failure keeps the optimistic message and its attachments in chat")
  func failedSubmissionRemainsInChat() async throws {
    let fixture = try Fixture()
    fixture.controller.composerAttachments = [attachment()]
    fixture.client.promptFailure = .httpStatus(503, "Please retry")

    await fixture.controller.send()

    #expect(fixture.promotions == 1)
    #expect(fixture.controller.hasAcceptedFirstSend)
    #expect(!fixture.controller.shouldShowNewChatComposer)
    #expect(fixture.controller.composerText.isEmpty)
    #expect(fixture.controller.composerAttachments.isEmpty)
    #expect(fixture.controller.model?.errorMessage == "Please retry")
    let message = try #require(userMessages(in: fixture.controller).first)
    #expect(message.text == "Send this message")
    #expect(message.attachments.map(\.name) == ["note.txt"])
    #expect(userMessages(in: fixture.controller).count == 1)
    fixture.controller.model?.shutdown()
  }

  @Test("Setup failure restores the submitted draft and attachments like macOS")
  func setupFailureRestoresDraft() async throws {
    let fixture = try Fixture()
    let staged = attachment()
    fixture.controller.composerAttachments = [staged]
    fixture.client.openSessionFailure = .httpStatus(503, "Setup failed")
    var didFailSetup = false
    fixture.controller.onSetupFailed = { didFailSetup = true }

    await fixture.controller.send()

    #expect(fixture.promotions == 1)
    #expect(didFailSetup)
    #expect(!fixture.controller.hasAcceptedFirstSend)
    #expect(fixture.controller.shouldShowNewChatComposer)
    #expect(fixture.controller.composerText == "Send this message")
    #expect(fixture.controller.composerAttachments == [staged])
    #expect(fixture.controller.model == nil)
    #expect(fixture.controller.pendingUserMessage == nil)
    #expect(fixture.controller.userSendAnimationRequest == nil)
    #expect(fixture.client.promptedTexts.isEmpty)
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
    // Intake and presentation are separate: wait for the observable model
    // to apply the event, not merely for the transport to deliver it.
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

  private func userMessages(in controller: SessionController) -> [UserMessage] {
    controller.conversation.compactMap { item in
      if case let .user(message) = item { return message }
      return nil
    }
  }

  private func attachment() -> ComposerAttachment {
    ComposerAttachment(
      id: UUID(), name: "note.txt", mimeType: "text/plain", kind: .file,
      localData: Data("note".utf8),
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
            "origin": "codevisor", "isArchived": false, "createdAt": "2026-09-08T17:45:00Z",
          ],
          "transcript": ["items": [], "hasMore": false, "eventCursor": 0],
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
        #expect(controller.pendingUserMessage?.text == text)
        #expect(controller.userSendAnimationRequest != nil)
        controller.serverSession = ChatSession(
          id: sessionID, projectId: project.id, serverId: project.serverId,
          harnessId: "codex", title: text, createdAt: Date(timeIntervalSince1970: 0)
        )
      }
    }
  }
}

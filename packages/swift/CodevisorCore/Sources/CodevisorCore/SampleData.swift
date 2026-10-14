import Foundation
import ACPKit

public enum SampleData {
  public static var conversation: [ConversationItem] {
    var turn = AssistantTurn(
      isGenerating: false,
      stopReason: .endTurn,
      startedAt: Date(timeIntervalSince1970: 0),
      endedAt: Date(timeIntervalSince1970: 14)
    )
    TranscriptReducer.apply(.agentMessageChunk(.text("I'll ground this in the current checkout first.")), to: &turn)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(
          toolCallId: "exec-1",
          title: "Ran rg -n \"actor|connection\" Sources",
          kind: .execute,
          status: .completed,
          content: [.content(.text("$ rg -n \"actor\"\nSources/ACPKit/Client/ACPConnection.swift:14"))]
        )), to: &turn)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(
          toolCallId: "search-1", title: "Searched for files", kind: .search, status: .completed
        )), to: &turn)
    TranscriptReducer.apply(
      .agentMessageChunk(.text("The README matches the layout. Reading the entrypoints now.")), to: &turn)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(
          toolCallId: "read-1", title: "Read Package.swift", kind: .read, status: .completed,
          content: [.content(.text("// swift-tools-version: 6.0"))]
        )), to: &turn)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(
          toolCallId: "read-2", title: "Read ACPConnection.swift", kind: .read, status: .completed
        )), to: &turn)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(
          toolCallId: "read-3", title: "Read ACPClient.swift", kind: .read, status: .completed
        )), to: &turn)
    TranscriptReducer.apply(
      .agentMessageChunk(
        .text(
          """
          Here's what I found:

          - The package targets **macOS 26**
          - It uses an `actor` for the connection

          ```swift
          public actor ACPConnection {
              // ...
          }
          ```
          """)), to: &turn)

    return [
      .user(UserMessage(text: "How is the ACP connection implemented?")),
      .assistant(AssistantMessage(turn: turn)),
    ]
  }

  public static var configOptions: [SessionConfigOption] {
    [
      SessionConfigOption(
        id: "model", name: "Model", category: "model", currentValue: "gpt-5.5",
        options: [
          SessionConfigSelectOption(value: "gpt-5.5", name: "GPT-5.5"),
          SessionConfigSelectOption(value: "gpt-5.4", name: "GPT-5.4"),
          SessionConfigSelectOption(value: "gpt-5.4-mini", name: "GPT-5.4-Mini"),
        ]
      ),
      SessionConfigOption(
        id: "reasoning_effort", name: "Reasoning effort", category: "thought_level", currentValue: "high",
        options: [
          SessionConfigSelectOption(value: "low", name: "Low"),
          SessionConfigSelectOption(value: "medium", name: "Medium"),
          SessionConfigSelectOption(value: "high", name: "High"),
        ]
      ),
      SessionConfigOption(
        id: "speed", name: "Speed", category: "speed", currentValue: "fast",
        options: [
          SessionConfigSelectOption(value: "standard", name: "Standard"),
          SessionConfigSelectOption(
            value: "fast", name: "Fast", description: "Prioritized, faster responses"
          ),
        ]
      ),
    ]
  }

  public static var streamingConversation: [ConversationItem] {
    var turn = AssistantTurn(isGenerating: true, isThinking: true, startedAt: Date(timeIntervalSince1970: 0))
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(
          toolCallId: "t1", title: "Running tests", kind: .execute, status: .inProgress
        )), to: &turn)
    return [
      .user(UserMessage(text: "Run the test suite")),
      .assistant(AssistantMessage(turn: turn)),
    ]
  }
}

public extension SessionModel {
  @MainActor
  static func preview(
    conversation: [ConversationItem] = SampleData.conversation,
    isSending: Bool = false,
    modeState: SessionModeState? = SessionModeState(
      currentModeId: "default",
      availableModes: [
        SessionMode(id: "default", name: "Default", canonicalId: "fullAccess"),
        SessionMode(id: "plan", name: "Plan", canonicalId: "plan"),
      ]
    ),
    configOptions: [SessionConfigOption] = SampleData.configOptions,
    usage: SessionUsage? = SessionUsage(
      used: 18_432, size: 200_000, cost: SessionCost(amount: 0.0142, currency: "USD"))
  ) -> SessionModel {
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: PreviewServerClient(), sessionId: UUID()),
      sessionId: "preview",
      modeState: modeState,
      configOptions: configOptions
    )
    model.applyPreviewState(conversation: conversation, isSending: isSending, usage: usage)
    return model
  }
}

@MainActor
final class PreviewCloudMachines: CloudMachineProviding {
  let cloudMachines: [CloudMachine]
  let isCloudSignedIn = true
  let isCloudRosterVerified = true

  init(cloudMachines: [CloudMachine]) {
    self.cloudMachines = cloudMachines
  }

  func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? { nil }
}

struct PreviewServerClient: CodevisorServerClienting {
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    ServerNavigationSnapshot(
      eventCursor: 0, projects: try await listProjects(), sessions: try await listSessions(), workspaces: [], panes: [])
  }

  var harnessCapabilities: [ServerHarnessCapability] = []

  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.0.0", database: "ready")
  }

  func info() async throws -> ServerInfo { throw CodevisorServerClientError.invalidResponse }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    throw CodevisorServerClientError.invalidResponse
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities {
    ServerCapabilities(harnesses: harnessCapabilities)
  }
  func listHarnesses() async throws -> [ServerHarness] { harnessCapabilities.map(\.harness) }
  func listProjects() async throws -> [ServerProject] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteProject(id: UUID) async throws {}
  func listSessions() async throws -> [ServerSession] { [] }
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
}

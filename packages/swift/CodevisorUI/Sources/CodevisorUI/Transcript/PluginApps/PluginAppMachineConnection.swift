import CodevisorCore
import Foundation
import TranscriptKit

@MainActor
public struct PluginAppMachineConnection: PluginAppConnecting {
  public let environment: AppEnvironment
  public let machineId: String
  public let chatSessionId: UUID?
  public let chatMachineId: String

  public init(environment: AppEnvironment, machineId: String, chatSessionId: UUID? = nil, chatMachineId: String? = nil)
  {
    self.environment = environment
    self.machineId = machineId
    self.chatSessionId = chatSessionId
    self.chatMachineId = chatMachineId ?? machineId
  }

  public var canOpenFullscreen: Bool { false }

  public func launch(_ app: CodevisorExecutionApp) async throws -> PluginAppLaunch {
    let response = try await client.issuePluginAppViewToken(viewId: app.viewId)
    return PluginAppLaunch(path: response.url, issuedAt: Date())
  }

  public func baseURL(for app: CodevisorExecutionApp) async -> URL? {
    await environment.machines.effectiveHTTPBaseURL(forMachineId: machineId)
  }

  public func subject(for app: CodevisorExecutionApp) async throws -> PluginModerationSubject? {
    let servers = try await client.listMcpServers()
    return servers.first { $0.id == app.serverId }.map(PluginModerationSubject.init(server:))
  }

  public func openFullscreen(_ app: CodevisorExecutionApp) -> Bool { false }

  public func sendMessage(_ text: String, from app: CodevisorExecutionApp) {
    PluginAppChatMessage.send(
      text, from: app, to: chatSessionId, client: environment.machines.client(for: chatMachineId))
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machineId)
  }
}

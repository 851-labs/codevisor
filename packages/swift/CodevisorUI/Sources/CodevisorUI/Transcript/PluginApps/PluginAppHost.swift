import CodevisorCore
import Foundation
import TranscriptKit

@MainActor
public struct PluginAppHost: PluginAppConnecting {
  public let environment: AppEnvironment
  public let session: SessionController
  public let presenter: PluginAppPresenter?

  public init(environment: AppEnvironment, session: SessionController, presenter: PluginAppPresenter? = nil) {
    self.environment = environment
    self.session = session
    self.presenter = presenter
  }

  public var chatMachineId: String { session.project.serverId }

  public var chatSessionId: UUID? { session.serverSession?.id }

  public var canOpenFullscreen: Bool { presenter != nil }

  public func launch(_ app: CodevisorExecutionApp) async throws -> PluginAppLaunch {
    try await machine(for: app).launch(app)
  }

  public func baseURL(for app: CodevisorExecutionApp) async -> URL? {
    await machine(for: app).baseURL(for: app)
  }

  public func subject(for app: CodevisorExecutionApp) async throws -> PluginModerationSubject? {
    try await machine(for: app).subject(for: app)
  }

  public func openFullscreen(_ app: CodevisorExecutionApp) -> Bool {
    guard let presenter else { return false }

    return presenter.open(PluginAppPaneLink.resource(for: app, chatMachineId: chatMachineId), chatSessionId)
  }

  public func sendMessage(_ text: String, from app: CodevisorExecutionApp) {
    PluginAppChatMessage.send(
      text, from: app, to: chatSessionId, client: environment.machines.client(for: chatMachineId))
  }

  private func machine(for app: CodevisorExecutionApp) -> PluginAppMachineConnection {
    PluginAppMachineConnection(environment: environment, machineId: app.owningMachineId(fallback: chatMachineId))
  }
}

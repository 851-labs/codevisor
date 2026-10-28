import CodevisorCore
import Foundation
import Observation
import TranscriptKit

@MainActor
@Observable
public final class PluginAppPaneModel {
  public let paneId: UUID
  public let app: CodevisorExecutionApp
  public let page: PluginAppPage
  public let lookup = PluginAppSubjectLookup()
  public let environment: AppEnvironment
  public private(set) var appModes: Set<PluginAppDisplayMode>?

  @ObservationIgnored public var onBack: (() -> Void)?
  @ObservationIgnored let key: String
  @ObservationIgnored private let ownerChatSessionId: UUID?
  @ObservationIgnored private let connection: PluginAppMachineConnection
  @ObservationIgnored private let registry: PluginAppDisplayRegistry
  @ObservationIgnored private let inlineModels: PluginAppInlineModelCache

  public init(
    paneId: UUID, resource: PluginAppPaneResource, fallbackMachineId: String, ownerChatSessionId: UUID?,
    environment: AppEnvironment
  ) {
    let machineId = resource.machineId ?? fallbackMachineId
    var app = PluginAppPaneLink.app(from: resource)
    app.machineId = machineId
    self.paneId = paneId
    self.app = app
    self.page = PluginAppPage(app: app)
    self.environment = environment
    self.key = PluginAppInlineModelCache.key(app, chatMachineId: machineId)
    self.ownerChatSessionId = ownerChatSessionId
    self.connection = PluginAppMachineConnection(
      environment: environment, machineId: machineId, chatSessionId: ownerChatSessionId,
      chatMachineId: fallbackMachineId)
    self.registry = .shared
    self.inlineModels = .shared
    page.onMessage = { [weak self] message in self?.receive(message) }
    registry.beginFullscreen(key)
  }

  public var subject: PluginModerationSubject? { lookup.subject }

  public func canEnterPip() -> Bool {
    appModes?.contains(.pip) ?? true
  }

  public func appear() {
    lookup.resolve(app, connection: connection)
  }

  public func show(display: PluginAppDisplay) {
    var display = display
    display.mode = .fullscreen
    display.hostModes = PluginAppDisplayMode.allCases
    page.show(display: display, connection: connection)
  }

  public func suspend() {
    page.suspend()
  }

  public func retry() {
    guard subject != nil else {
      lookup.retry(app, connection: connection)
      return
    }
    page.retry()
  }

  public func close() {
    registry.endFullscreen(key)
    page.suspend()
  }

  public func enterPip() {
    let inline = inlineModels.model(for: app, chatMachineId: connection.machineId)
    inline.attach(connection, chatSessionId: ownerChatSessionId)
    close()
    inline.request(.pip)
    onBack?()
  }

  private func receive(_ message: PluginAppNativeMessage) {
    switch message {
    case let .displayMode(.inline, requestId):
      page.notifyDisplayMode(.inline, requestId: requestId)
      onBack?()
    case let .displayMode(.pip, requestId) where canEnterPip():
      page.notifyDisplayMode(.pip, requestId: requestId)
      enterPip()
    case let .displayMode(_, requestId):
      page.notifyDisplayMode(.fullscreen, requestId: requestId)
    case let .appModes(modes):
      appModes = modes
    case let .message(text, viewId) where viewId == app.viewId:
      connection.sendMessage(text, from: app)
    case .message, .size, .openLink, .frameFailed:
      break
    }
  }
}

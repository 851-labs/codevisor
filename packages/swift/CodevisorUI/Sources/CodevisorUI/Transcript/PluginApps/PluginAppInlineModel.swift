import CodevisorCore
import CoreGraphics
import Foundation
import Observation
import TranscriptKit

@MainActor
@Observable
public final class PluginAppInlineModel {
  public let app: CodevisorExecutionApp
  public let key: String
  public let page: PluginAppPage
  public let lookup = PluginAppSubjectLookup()
  public private(set) var appModes: Set<PluginAppDisplayMode>?
  public private(set) var chatSessionId: UUID?

  @ObservationIgnored private(set) var connection: (any PluginAppConnecting)?
  @ObservationIgnored private let registry: PluginAppDisplayRegistry

  init(
    app: CodevisorExecutionApp, key: String, height: CGFloat? = nil,
    registry: PluginAppDisplayRegistry = .shared
  ) {
    self.app = app
    self.key = key
    self.page = PluginAppPage(app: app, height: height)
    self.registry = registry
    page.onMessage = { [weak self] message in self?.receive(message) }
  }

  public var mode: PluginAppDisplayMode { registry.mode(for: self) }

  public var subject: PluginModerationSubject? { lookup.subject }

  public func canPresent(_ mode: PluginAppDisplayMode) -> Bool {
    guard appModes?.contains(mode) ?? true else { return false }
    guard mode == .fullscreen else { return true }

    return connection?.canOpenFullscreen == true
  }

  var hostModes: [PluginAppDisplayMode] {
    PluginAppDisplayMode.allCases.filter { $0 != .fullscreen || connection?.canOpenFullscreen == true }
  }

  func attach(_ connection: any PluginAppConnecting, chatSessionId: UUID?) {
    if prefers(connection) { self.connection = connection }
    if let chatSessionId { self.chatSessionId = chatSessionId }
    lookup.resolve(app, connection: connection)
  }

  public func request(_ mode: PluginAppDisplayMode, requestId: String? = nil) {
    guard mode != self.mode, canPresent(mode) else {
      page.notifyDisplayMode(self.mode, requestId: requestId)
      return
    }

    switch mode {
    case .inline: registry.endPip(self)
    case .pip: registry.startPip(self)
    case .fullscreen: openFullscreen()
    }
    page.notifyDisplayMode(self.mode, requestId: requestId)
  }

  public func revealFullscreen() {
    _ = connection?.openFullscreen(app)
  }

  public func retry() {
    guard let connection else { return }
    guard subject != nil else {
      lookup.retry(app, connection: connection)
      return
    }

    page.retry()
  }

  func show(display: PluginAppDisplay) {
    guard let connection else { return }

    var display = display
    display.mode = mode
    display.hostModes = hostModes
    page.show(display: display, connection: connection)
  }

  private func prefers(_ candidate: any PluginAppConnecting) -> Bool {
    candidate.canOpenFullscreen || connection?.canOpenFullscreen != true
  }

  private func openFullscreen() {
    guard connection?.openFullscreen(app) == true else { return }

    registry.beginFullscreen(key)
  }

  private func receive(_ message: PluginAppNativeMessage) {
    switch message {
    case let .displayMode(mode, requestId):
      request(mode, requestId: requestId)
    case let .appModes(modes):
      appModes = modes
    case let .message(text, viewId) where viewId == app.viewId:
      connection?.sendMessage(text, from: app)
    case .message, .size, .openLink:
      break
    }
  }
}

import CodevisorCore
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorUI

@MainActor
@Suite("Inline plugin app display modes")
struct PluginAppDisplayModeTests {
  private let registry = PluginAppDisplayRegistry()

  private func model(_ viewId: String, opensTabs: Bool = true) -> (PluginAppInlineModel, FakeAppConnection) {
    let app = CodevisorExecutionApp(
      viewId: viewId, serverId: "mcp", serverName: "Zillow", toolName: "search", resourceUri: "ui://z")
    let model = PluginAppInlineModel(app: app, key: "local|\(viewId)", registry: registry)
    let connection = FakeAppConnection(canOpenFullscreen: opensTabs)
    model.attach(connection, chatSessionId: UUID())
    return (model, connection)
  }

  @Test("Only one app plays in picture in picture; starting another returns the first to the chat")
  func onePip() {
    let (first, _) = model("v1")
    let (second, _) = model("v2")

    first.request(.pip)
    #expect(first.mode == .pip)

    second.request(.pip)
    #expect(second.mode == .pip)
    #expect(first.mode == .inline)

    second.request(.inline)
    #expect(registry.pip == nil)
  }

  @Test("Opening an app in a tab takes it out of picture in picture until the tab closes")
  func fullscreen() {
    let (app, connection) = model("v1")
    app.request(.pip)

    app.request(.fullscreen)

    #expect(connection.openedViews == ["v1"])
    #expect(app.mode == .fullscreen)
    #expect(registry.pip == nil)
    registry.endFullscreen(app.key)
    #expect(app.mode == .inline)
  }

  @Test("A mode the host can't show or the app didn't declare leaves the app where it is")
  func declinedModes() {
    let (chatOnly, connection) = model("v1", opensTabs: false)
    chatOnly.request(.fullscreen)
    #expect(connection.openedViews.isEmpty)
    #expect(chatOnly.mode == .inline)
    #expect(!chatOnly.canPresent(.fullscreen))

    let (declared, _) = model("v2")
    #expect(declared.canPresent(.pip))
    declared.page.onMessage?(.appModes([.inline, .fullscreen]))
    declared.request(.pip)
    #expect(declared.mode == .inline)
    #expect(!declared.canPresent(.pip))
    #expect(declared.canPresent(.fullscreen))
  }

  @Test("An app's own request goes through the same rules as the header buttons")
  func appRequests() {
    let (app, connection) = model("v1")

    app.page.onMessage?(.displayMode(.fullscreen, requestId: "display-mode-1"))

    #expect(connection.openedViews == ["v1"])
    #expect(app.mode == .fullscreen)
  }
}

extension PluginAppDisplayModeTests {
  @Test("An app's message reaches its chat only when it names this view")
  func messages() {
    let (app, connection) = model("v1")

    app.page.onMessage?(.message("Tour it", viewId: "v1"))
    app.page.onMessage?(.message("Not mine", viewId: "v2"))

    #expect(connection.sentMessages == ["v1: Tour it"])
  }
}

@MainActor
private final class FakeAppConnection: PluginAppConnecting {
  let canOpenFullscreen: Bool
  private(set) var openedViews: [String] = []

  init(canOpenFullscreen: Bool) {
    self.canOpenFullscreen = canOpenFullscreen
  }

  func launch(_ app: CodevisorExecutionApp) async throws -> PluginAppLaunch {
    PluginAppLaunch(path: "/v1/plugins/apps/\(app.viewId)?token=t", issuedAt: Date(timeIntervalSince1970: 0))
  }

  func baseURL(for app: CodevisorExecutionApp) async -> URL? { nil }

  func subject(for app: CodevisorExecutionApp) async throws -> PluginModerationSubject? { nil }

  func openFullscreen(_ app: CodevisorExecutionApp) -> Bool {
    guard canOpenFullscreen else { return false }

    openedViews.append(app.viewId)
    return true
  }

  private(set) var sentMessages: [String] = []

  func sendMessage(_ text: String, from app: CodevisorExecutionApp) {
    sentMessages.append("\(app.viewId): \(text)")
  }
}

import CodevisorCore
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorUI

@MainActor
@Suite("Inline plugin app display modes")
struct PluginAppDisplayModeTests {
  private let registry = PluginAppDisplayRegistry()

  private func model(
    _ viewId: String, fullscreen: PluginAppFullscreen = .tab
  ) -> (PluginAppInlineModel, FakeAppConnection) {
    let app = CodevisorExecutionApp(
      viewId: viewId, serverId: "mcp", serverName: "Zillow", toolName: "search", resourceUri: "ui://z")
    let model = PluginAppInlineModel(app: app, key: "local|\(viewId)", registry: registry)
    let connection = FakeAppConnection(fullscreen: fullscreen)
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

    #expect(connection.openedViews == ["v1 in tab"])
    #expect(app.mode == .fullscreen)
    #expect(registry.pip == nil)
    registry.endFullscreen(app.key)
    #expect(app.mode == .inline)
  }

  @Test("Beside a code chat an app's full screen request opens a split, or a tab when the split won't fit")
  func split() {
    let (app, connection) = model("v1", fullscreen: .split)
    let (cramped, crampedConnection) = model("v2", fullscreen: .split)
    crampedConnection.opensSplit = false

    app.request(.fullscreen)
    cramped.request(.fullscreen)

    #expect(connection.openedViews == ["v1 in split"])
    #expect(app.panePlacement == .split)
    #expect(app.showsInPane)
    #expect(crampedConnection.openedViews == ["v2 in tab"])
    #expect(cramped.panePlacement == .tab)
    #expect(cramped.mode == .fullscreen)
  }

  @Test("A mode the host can't show or the app didn't declare leaves the app where it is")
  func declinedModes() {
    let (chatOnly, connection) = model("v1", fullscreen: .unavailable)
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

    #expect(connection.openedViews == ["v1 in tab"])
    #expect(app.mode == .fullscreen)
  }
}

extension PluginAppDisplayModeTests {
  @Test("Each surface offers only the modes it can show")
  func hostModes() {
    let (bot, _) = model("v1", fullscreen: .unavailable)
    let (code, _) = model("v2", fullscreen: .split)

    #expect(bot.hostModes == [.inline, .pip])
    #expect(code.hostModes == [.inline, .fullscreen, .pip])
  }

  @Test("An app asking to close leaves picture in picture first, then closes in the chat until reopened")
  func requestedTeardown() {
    let (app, _) = model("v1")
    app.request(.pip)

    app.page.onMessage?(.requestTeardown)
    #expect(app.mode == .inline)
    #expect(app.page.phase != .closed)

    app.page.onMessage?(.requestTeardown)
    #expect(app.page.phase == .closed)
  }

  @Test("Picture in picture remembers when it started")
  func pipStart() {
    let started = Date(timeIntervalSince1970: 500)
    let registry = PluginAppDisplayRegistry(now: { started })
    let app = PluginAppInlineModel(
      app: CodevisorExecutionApp(
        viewId: "v1", serverId: "mcp", serverName: "Zillow", toolName: "search", resourceUri: "ui://z"),
      key: "local|v1", registry: registry)
    let chat = UUID()
    app.attach(FakeAppConnection(fullscreen: .tab), chatSessionId: chat)

    app.request(.pip)

    #expect(registry.pipStartedAt == started)
    #expect(registry.pip(forChat: chat) === app)
    #expect(registry.pip(forChat: UUID()) == nil)
  }

  @Test("An app's message reaches its chat only when it names this view")
  func messages() {
    let (app, connection) = model("v1")

    app.page.onMessage?(.message("Tour it", viewId: "v1"))
    app.page.onMessage?(.message("Not mine", viewId: "v2"))

    #expect(connection.sentMessages == ["v1: Tour it"])
  }
}

@MainActor
final class FakeAppConnection: PluginAppConnecting {
  let fullscreen: PluginAppFullscreen
  private(set) var openedViews: [String] = []

  init(fullscreen: PluginAppFullscreen) {
    self.fullscreen = fullscreen
  }

  func launch(_ app: CodevisorExecutionApp) async throws -> PluginAppLaunch {
    PluginAppLaunch(path: "/v1/plugins/apps/\(app.viewId)?token=t", issuedAt: Date(timeIntervalSince1970: 0))
  }

  func baseURL(for app: CodevisorExecutionApp) async -> URL? { nil }

  func subject(for app: CodevisorExecutionApp) async throws -> PluginModerationSubject? { nil }

  var opensSplit = true

  func openFullscreen(_ app: CodevisorExecutionApp, in placement: PluginAppPanePlacement) -> PluginAppPanePlacement? {
    guard canOpenFullscreen else { return nil }

    let opened = placement == .split && opensSplit ? PluginAppPanePlacement.split : .tab
    openedViews.append("\(app.viewId) in \(opened)")
    return opened
  }

  private(set) var sentMessages: [String] = []

  func sendMessage(_ text: String, from app: CodevisorExecutionApp) {
    sentMessages.append("\(app.viewId): \(text)")
  }
}

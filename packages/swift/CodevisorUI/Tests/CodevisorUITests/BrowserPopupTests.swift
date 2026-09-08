import CodevisorClient
import Foundation
import Testing
import WebKit
@testable import CodevisorUI

@MainActor
@Suite("WebKit popup adoption")
struct BrowserPopupTests {
  @Test func childrenKeepTheBrowserProfileButOwnTheirNavigationHandlers() throws {
    let endpoint = try #require(URL(string: "https://unused.invalid"))
    let client = CodevisorServerClient(config: CodevisorServerConfig(baseURL: endpoint))
    let parent = BrowserPaneModel(
      paneId: UUID(), machineId: "popup-test", machineName: "Fixture", initialURL: nil,
      client: client, resolveBaseURL: { nil })
    let child = BrowserPaneModel(
      paneId: UUID(), machineId: "popup-test", machineName: "Fixture", initialURL: nil,
      client: client, resolveBaseURL: { nil })
    defer { parent.teardown(); child.teardown() }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.webExtensionController = WKWebExtensionController(configuration: .nonPersistent())
    configuration.userContentController.addUserScript(
      WKUserScript(source: "window.fixtureRouting = true", injectionTime: .atDocumentStart, forMainFrameOnly: false))
    let parentView = parent.adoptPopup(configuration: configuration)
    let childView = child.adoptPopup(configuration: parentView.configuration)
    #expect(childView.configuration.websiteDataStore === parentView.configuration.websiteDataStore)
    #expect(childView.configuration.webExtensionController === parentView.configuration.webExtensionController)
    #expect(childView.configuration.userContentController !== parentView.configuration.userContentController)
    let scripts = childView.configuration.userContentController.userScripts.map(\.source)
    #expect(scripts == parentView.configuration.userContentController.userScripts.map(\.source))
    #expect(scripts.count == 2, "Inherit routing and install the navigation observer exactly once")
    var closed = false
    child.onClose = { closed = true }
    child.webViewDidClose(childView)
    #expect(closed)
    #expect(parent.webView === parentView)
  }
}

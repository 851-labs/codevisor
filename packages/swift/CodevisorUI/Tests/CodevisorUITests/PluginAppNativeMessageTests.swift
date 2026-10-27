import Foundation
import Testing

@testable import CodevisorUI

@Suite("Inline plugin app native messages")
struct PluginAppNativeMessageTests {
  @Test("Size messages are rounded up and clamped to the inline range")
  func size() {
    #expect(PluginAppNativeMessage(body: ["type": "size", "height": 312.2]) == .size(height: 313))
    #expect(PluginAppNativeMessage(body: ["type": "size", "height": 4]) == .size(height: 80))
    #expect(PluginAppNativeMessage(body: ["type": "size", "height": 5_000]) == .size(height: 720))
    #expect(PluginAppNativeMessage(body: ["type": "size", "height": Double.infinity]) == nil)
    #expect(PluginAppNativeMessage(body: ["type": "size", "height": "300"]) == nil)
  }

  @Test("Only web and mail links open externally")
  func links() throws {
    let web = try #require(URL(string: "https://www.zillow.com/homedetails/1"))
    let mail = try #require(URL(string: "mailto:agent@example.com"))

    #expect(PluginAppNativeMessage(body: ["type": "openLink", "url": web.absoluteString]) == .openLink(web))
    #expect(PluginAppNativeMessage(body: ["type": "openLink", "url": mail.absoluteString]) == .openLink(mail))
    #expect(PluginAppNativeMessage(body: ["type": "openLink", "url": "file:///etc/passwd"]) == nil)
    #expect(PluginAppNativeMessage(body: ["type": "openLink", "url": "codevisor://settings"]) == nil)
    #expect(PluginAppNativeMessage(body: ["type": "openLink", "url": "javascript:alert(1)"]) == nil)
  }

  @Test("Messages need the view that sent them; trimmed text is kept and blank or unknown messages are dropped")
  func messages() {
    #expect(
      PluginAppNativeMessage(body: ["type": "message", "text": "  Tour 12 Main St \n", "viewId": "v1"])
        == .message("Tour 12 Main St", viewId: "v1"))
    #expect(PluginAppNativeMessage(body: ["type": "message", "text": "Tour it"]) == nil)
    #expect(PluginAppNativeMessage(body: ["type": "message", "text": " ", "viewId": "v1"]) == nil)
    #expect(PluginAppNativeMessage(body: ["type": "camera"]) == nil)
    #expect(PluginAppNativeMessage(body: "size") == nil)
  }

  @Test("Display mode requests carry the shell's request id, and declared app modes ignore unknown names")
  func displayModes() {
    #expect(
      PluginAppNativeMessage(body: ["type": "displayMode", "mode": "fullscreen", "requestId": "display-mode-1"])
        == .displayMode(.fullscreen, requestId: "display-mode-1"))
    #expect(PluginAppNativeMessage(body: ["type": "displayMode", "mode": "pip"]) == .displayMode(.pip, requestId: nil))
    #expect(PluginAppNativeMessage(body: ["type": "displayMode", "mode": "theater"]) == nil)
    #expect(
      PluginAppNativeMessage(body: ["type": "appModes", "modes": ["inline", "pip", "theater"]])
        == .appModes([.inline, .pip]))
  }
}

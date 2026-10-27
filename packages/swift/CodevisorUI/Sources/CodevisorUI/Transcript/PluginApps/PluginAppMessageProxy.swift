import WebKit

final class PluginAppMessageProxy: NSObject, WKScriptMessageHandler {
  weak var controller: PluginAppWebController?

  init(controller: PluginAppWebController) {
    self.controller = controller
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame else { return }
    controller?.receive(message.body)
  }
}

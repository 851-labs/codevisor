import Foundation
import WebKit

@MainActor
enum BrowserNetworkRules {
  static func redirectedNavigation(_ request: URLRequest) -> URLRequest? {
    guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.user == nil, url.password == nil,
      let target = BrowserAddress.proxied(url), target != url
    else { return nil }
    var redirected = request
    redirected.url = target
    return redirected
  }

  static func makeWebView(store: WKWebsiteDataStore) async throws -> WKWebView {
    guard let resources = Bundle.module.url(forResource: "BrowserRouting", withExtension: nil) else {
      throw URLError(.fileDoesNotExist)
    }
    let webExtension = try await WKWebExtension(resourceBaseURL: resources)
    if let error = webExtension.errors.first { throw error }
    let context = WKWebExtensionContext(for: webExtension)
    context.hasAccessToPrivateData = true
    context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
    context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
    for pattern in webExtension.requestedPermissionMatchPatterns {
      context.setPermissionStatus(.grantedExplicitly, for: pattern)
    }
    let controller = WKWebExtensionController(configuration: .nonPersistent())
    let readiness = BrowserRoutingReadiness()
    controller.delegate = readiness
    try controller.load(context)

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    configuration.webExtensionController = controller
    configuration.upgradeKnownHostsToHTTPS = false
    let socketScript = try String(contentsOf: resources.appendingPathComponent("websocket.js"), encoding: .utf8)
    configuration.userContentController.addUserScript(
      WKUserScript(source: socketScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    let view = WKWebView(frame: .zero, configuration: configuration)

    try await readiness.wait(context: context)
    controller.delegate = nil
    if let error = context.errors.first { throw error }
    try Task.checkCancellation()
    return view
  }
}

@MainActor
private final class BrowserRoutingReadiness: NSObject, WKWebExtensionControllerDelegate {
  private var continuation: CheckedContinuation<Void, any Error>?
  private var result: Result<Void, any Error>?

  func wait(context: WKWebExtensionContext) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        if Task.isCancelled { finish(.failure(CancellationError())); return }
        if let result { finish(result); return }
        context.loadBackgroundContent { error in
          if let error { self.finish(.failure(error)) }
        }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  func webExtensionController(
    _ controller: WKWebExtensionController, sendMessage message: Any,
    toApplicationWithIdentifier applicationIdentifier: String?, for context: WKWebExtensionContext,
    replyHandler: @escaping (Any?, (any Error)?) -> Void
  ) {
    guard applicationIdentifier == "codevisor.browser-routing", let message = message as? [String: Any] else {
      replyHandler(nil, URLError(.unsupportedURL))
      return
    }
    if message["ready"] as? Bool == true {
      finish(.success(()))
    } else {
      finish(
        .failure(
          NSError(
            domain: "BrowserRouting", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: message["error"] as? String ?? "Couldn’t install browser routing rules."
            ])))
    }
    replyHandler(true, nil)
  }

  private func finish(_ result: Result<Void, any Error>) {
    if self.result == nil { self.result = result }
    let pending = continuation
    continuation = nil
    pending?.resume(with: self.result ?? result)
  }
}

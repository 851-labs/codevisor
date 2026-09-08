import AppKit
import CodevisorClient
import CryptoKit
import Foundation
import Network
import Testing
import WebKit
@testable import CodevisorUI

/// Real WebKit and loopback sockets are intentional: this verifies Apple's
/// networking boundary, especially the historically special localhost route.
@MainActor
@Suite("WebKit browser proxy", .serialized, .timeLimit(.minutes(1)))
struct BrowserProxyWebKitTests {
  @Test func replacingTheProxyPreservesTheLoadedDocumentAndHistory() async throws {
    _ = NSApplication.shared
    let first = try ProxyFixture()
    defer { first.close() }
    let second = try ProxyFixture()
    defer { second.close() }
    let firstPort = try await first.start()
    let secondPort = try await second.start()
    let machineId = "proxy-recovery-\(UUID())"
    let credential = ServerBrowserProxySession(username: "test", password: "secret")
    let store = try BrowserWebsiteProfile.configuredStore(
      machineId: machineId, endpoint: URL(string: "http://127.0.0.1:\(firstPort)")!, credential: credential)
    let view = try await BrowserNetworkRules.makeWebView(store: store)
    let navigation = NavigationResult()
    view.navigationDelegate = navigation
    defer { view.stopLoading(); view.navigationDelegate = nil }
    let url = URL(string: "http://proxy.localhost:3000/")!
    try await navigation.load(view, url: url)
    _ = try await view.evaluateJavaScript("history.pushState({}, '', '/retained'); window.unsaved = 'keep me'")
    let history = view.backForwardList.backList.map(\.url)
    let updated = try BrowserWebsiteProfile.configuredStore(
      machineId: machineId, endpoint: URL(string: "http://127.0.0.1:\(secondPort)")!, credential: credential)
    #expect(updated === store)
    let response = try await view.callAsyncJavaScript(
      "return await (await fetch('http://recovered.proxy.localhost:3001/api')).text()",
      arguments: [:], in: nil, contentWorld: .page)
    #expect(response as? String == "proxied API")
    #expect(second.authorities.contains("recovered.proxy.localhost:3001"))
    #expect(try await view.evaluateJavaScript("window.unsaved") as? String == "keep me")
    #expect(view.url?.path == "/retained")
    #expect(view.backForwardList.backList.map(\.url) == history)
  }

  @Test func faviconRequestsAndLoopbackRedirectsUseThePageProxy() async throws {
    let proxy = try ProxyFixture()
    let port = try await proxy.start()
    defer { proxy.close() }
    let store = try BrowserWebsiteProfile.configuredStore(
      machineId: "favicon-test-\(UUID())", endpoint: URL(string: "http://127.0.0.1:\(port)")!,
      credential: ServerBrowserProxySession(username: "test", password: "secret"))
    let session = try BrowserFaviconLoader.session(for: store)
    defer { session.invalidateAndCancel() }
    let page = URL(string: "http://localhost:\(port)/")!
    let url = try #require(BrowserFaviconLoader.candidates(["/redirect-icon"], page: page).first)
    let data = try await BrowserFaviconLoader.download(url, session: session)
    #expect(String(decoding: data, as: UTF8.self) == "proxied API")
    #expect(proxy.authorities.contains("proxy.localhost:\(port)"))
    #expect(proxy.authorities.contains("ipv4-127-0-0-1.proxy.localhost:\(port)"))
    #expect(proxy.directRequests == 0)
    #expect(proxy.authorizedConnections >= 2)
  }

  @Test func remoteOriginsUseCONNECT() async throws {
    let host = "proxy.localhost"
    _ = NSApplication.shared
    let proxy = try ProxyFixture()
    let port = try await proxy.start()
    defer { proxy.close() }
    let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)"))
    let store = try BrowserWebsiteProfile.configuredStore(
      machineId: "webkit-test-\(UUID())", endpoint: endpoint,
      credential: ServerBrowserProxySession(username: "test", password: "secret")
    )
    let webView = try await BrowserNetworkRules.makeWebView(store: store)
    let navigation = NavigationResult()
    webView.navigationDelegate = navigation
    webView.uiDelegate = navigation
    defer { webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil }
    try await navigation.load(webView, url: URL(string: "http://\(host):3000/")!)
    let icons = try await webView.evaluateJavaScript(BrowserFaviconLoader.discoveryScript) as? [String]
    #expect(icons == ["http://\(host):3000/icon.png", "http://\(host):3000/icon.svg"])
    let initial = try await webView.callAsyncJavaScript(
      "return await window.initialRequest", arguments: [:], in: nil, contentWorld: .page)
    #expect(initial as? String == "proxied API")
    let result = try await webView.callAsyncJavaScript(
      "return await (await fetch('http://api.proxy.localhost:3001/api')).text()",
      arguments: [:], in: nil, contentWorld: .page
    )
    #expect(result as? String == "proxied API")
    #expect(try await webView.evaluateJavaScript("window.isSecureContext") as? Bool == true)
    #expect(proxy.authorities.contains("\(host):3000"))
    #expect(proxy.authorities.contains("api.proxy.localhost:3001"))
    #expect(proxy.authorizedConnections >= 2)
    // These ports are occupied on the client by the proxy fixture. Literal
    // subrequests must still reach CONNECT, never that listener directly.
    for localHost in ["localhost", "localhost.", "127.0.0.1", "127.4.3.2", "[::1]"] {
      let routed = try await webView.callAsyncJavaScript(
        "return await (await fetch(url)).text()",
        arguments: ["url": "http://\(localHost):\(port)/api"], in: nil, contentWorld: .page)
      #expect(routed as? String == "proxied API")
    }
    let post = try await webView.callAsyncJavaScript(
      "return await (await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({value: 42}) })).text()",
      arguments: ["url": "http://localhost:\(port)/api"], in: nil, contentWorld: .page)
    #expect(post as? String == #"{"value":42}"#)
    #expect(proxy.methods.contains("OPTIONS"))
    let imageBlocked = try await webView.callAsyncJavaScript(
      "return await new Promise(resolve => { const img = new Image(); img.onload = () => resolve(false); img.onerror = () => resolve(true); img.src = 'http://user:password@127.0.0.1:\(port)/private'; })",
      arguments: [:], in: nil, contentWorld: .page
    )
    #expect(imageBlocked as? Bool == true)
    #expect(proxy.directRequests == 0)
    let websocket = try await webView.callAsyncJavaScript(
      "return await new Promise((resolve, reject) => { const s = new WebSocket('ws://localhost:3002/hmr'); s.onmessage = e => { resolve(e.data); s.close() }; s.onerror = () => reject(new Error('WebSocket failed')); })",
      arguments: [:], in: nil, contentWorld: .page
    )
    #expect(websocket as? String == "proxied HMR")
    #expect(proxy.authorities.contains("proxy.localhost:3002"))
    #expect(webView.url?.absoluteString == "http://\(host):3000/")
    #expect(!webView.canGoBack)
    #expect(proxy.directRequests == 0)
    let worker = try await webView.callAsyncJavaScript(
      """
      return await new Promise((resolve, reject) => {
        const source = `onmessage = async e => { try { postMessage(await (await fetch(e.data)).text()); } catch { postMessage('blocked'); } };`;
        const objectURL = URL.createObjectURL(new Blob([source], {type: 'text/javascript'}));
        const worker = new Worker(objectURL);
        const cleanup = () => { worker.terminate(); URL.revokeObjectURL(objectURL); };
        worker.onmessage = e => { cleanup(); resolve(e.data); };
        worker.onerror = e => { cleanup(); reject(new Error(e.message)); };
        worker.postMessage(url);
      });
      """,
      arguments: ["url": "http://localhost:\(port)/api"], in: nil, contentWorld: .page)
    #expect(worker as? String == "proxied API")
    let workerSocket = try await webView.callAsyncJavaScript(
      """
      return await new Promise((resolve, reject) => {
        const source = `onmessage = e => { const s = new WebSocket(e.data); s.onmessage = e => postMessage(e.data); s.onerror = () => postMessage('blocked'); };`;
        const objectURL = URL.createObjectURL(new Blob([source], {type: 'text/javascript'}));
        const worker = new Worker(objectURL);
        const cleanup = () => { worker.terminate(); URL.revokeObjectURL(objectURL); };
        worker.onmessage = e => { cleanup(); resolve(e.data); };
        worker.onerror = e => { cleanup(); reject(new Error(e.message)); };
        worker.postMessage(url);
      });
      """,
      arguments: ["url": "ws://localhost:\(port)/hmr"], in: nil, contentWorld: .page)
    #expect(workerSocket as? String == "blocked")
    #expect(proxy.directRequests == 0)
    // A webpage link or redirect may navigate to literal localhost. Let the
    // navigation delegate handle it without adding extension pages to history.
    try await navigation.load(
      webView, url: URL(string: "http://localhost:\(port)/")!, pageScript: "location.href = url")
    #expect(webView.url?.absoluteString == "http://proxy.localhost:\(port)/")
    #expect(proxy.directRequests == 0)

    let frame = try await webView.callAsyncJavaScript(
      """
      return await new Promise((resolve, reject) => {
        const frame = document.createElement('iframe');
        frame.onload = () => { try { resolve(frame.contentDocument.body.textContent); } catch (e) { reject(e); } finally { frame.remove(); } };
        frame.onerror = () => reject(new Error('Frame failed'));
        frame.src = url;
        document.body.append(frame);
      });
      """,
      arguments: ["url": "http://localhost:\(port)/api"], in: nil, contentWorld: .page)
    #expect(frame as? String == "proxied API")
    try await navigation.load(
      webView, url: URL(string: "http://localhost:\(port)/api")!,
      pageScript: """
        const form = document.createElement('form');
        form.method = 'POST'; form.action = url;
        const input = document.createElement('input');
        input.name = 'value'; input.value = '42';
        form.append(input); document.body.append(form); form.requestSubmit();
        """)
    #expect(try await webView.evaluateJavaScript("document.body.textContent") as? String == "value=42")
    #expect(proxy.directRequests == 0)
  }
}

@MainActor
private final class NavigationResult: NSObject, WKNavigationDelegate, WKUIDelegate {
  private var continuation: CheckedContinuation<Void, any Error>?
  func load(_ view: WKWebView, url: URL, pageScript: String? = nil) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        if Task.isCancelled { finish(.failure(CancellationError())); return }
        if let pageScript {
          Task { @MainActor in
            do {
              _ = try await view.callAsyncJavaScript(
                pageScript, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
            } catch { self.finish(.failure(error)) }
          }
        } else {
          view.load(URLRequest(url: url))
        }
      }
    } onCancel: {
      Task { @MainActor in
        self.finish(.failure(CancellationError()))
        view.stopLoading()
      }
    }
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    webView.load(action.request)
    return nil
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    if navigationAction.targetFrame?.isMainFrame == true,
      let request = BrowserNetworkRules.redirectedNavigation(navigationAction.request)
    {
      webView.load(request)
      return .cancel
    }
    return .allow
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error)
  { finish(.failure(error)) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    finish(.failure(error))
  }
  private func finish(_ result: Result<Void, any Error>) {
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
}

@MainActor
private final class ProxyFixture {
  private let listener: NWListener
  private var connections: [NWConnection] = []
  var authorities: [String] = []
  var authorizedConnections = 0
  var directRequests = 0
  var methods: [String] = []

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        self?.connections.append(connection)
        connection.start(queue: .main)
        self?.read(connection, proxyHandshake: true, buffer: Data())
      }
    }
    return try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          if case .ready = state, let port = self.listener.port {
            self.listener.stateUpdateHandler = nil
            continuation.resume(returning: port.rawValue)
          } else if case let .failed(error) = state {
            self.listener.stateUpdateHandler = nil
            continuation.resume(throwing: error)
          }
        }
      }
      listener.start(queue: .main)
    }
  }

  func close() {
    listener.cancel()
    for connection in connections { connection.cancel() }
  }

  private func read(_ connection: NWConnection, proxyHandshake: Bool, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
      Task { @MainActor in
        guard let self, error == nil, !done else { return }
        var buffer = buffer
        if let data { buffer.append(data) }
        guard let header = String(data: buffer, encoding: .utf8), header.contains("\r\n\r\n") else {
          self.read(connection, proxyHandshake: proxyHandshake, buffer: buffer)
          return
        }
        let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))!.upperBound
        let contentLength =
          header.components(separatedBy: "\r\n")
          .first { $0.lowercased().hasPrefix("content-length:") }
          .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard buffer.count >= headerEnd + contentLength else {
          self.read(connection, proxyHandshake: proxyHandshake, buffer: buffer)
          return
        }
        let requestBody = String(decoding: buffer[headerEnd..<(headerEnd + contentLength)], as: UTF8.self)
        if !proxyHandshake { self.methods.append(header.components(separatedBy: " ")[0]) }
        if proxyHandshake && !header.hasPrefix("CONNECT ") {
          self.directRequests += 1
          self.send(
            connection,
            "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: content-type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nContent-Length: 6\r\n\r\ndirect"
          )
        } else if proxyHandshake {
          if !header.lowercased().contains(
            "proxy-authorization: basic \(Data("test:secret".utf8).base64EncodedString().lowercased())")
          {
            self.send(
              connection,
              "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Test\"\r\nContent-Length: 0\r\n\r\n"
            )
            self.read(connection, proxyHandshake: true, buffer: Data())
            return
          }
          self.authorizedConnections += 1
          self.authorities.append(header.components(separatedBy: " ")[1])
          self.send(connection, "HTTP/1.1 200 Connection Established\r\n\r\n")
          self.read(connection, proxyHandshake: false, buffer: Data())
        } else if header.hasPrefix("GET /redirect-icon ") {
          self.send(
            connection,
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(self.listener.port!.rawValue)/api\r\nContent-Length: 0\r\n\r\n"
          )
          self.read(connection, proxyHandshake: false, buffer: Data())
        } else if header.lowercased().contains("upgrade: websocket") {
          let key = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }!
            .components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
          let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
          self.send(
            connection,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n"
          )
          let message = Data("proxied HMR".utf8)
          connection.send(
            content: Data([0x81, UInt8(message.count)]) + message, completion: .contentProcessed { _ in })
        } else {
          let body: String
          if header.hasPrefix("POST /api ") {
            body = requestBody
          } else if header.hasPrefix("GET /api ") {
            body = "proxied API"
          } else {
            body = """
              <!doctype html><title>Proxied page</title>
              <link rel="icon" type="image/svg+xml" href="/icon.svg">
              <link rel="shortcut icon" href="/icon.png">
              <link rel="icon" media="not all" href="/hidden.png"><script>
              window.initialRequest = fetch('http://localhost:\(self.listener.port!.rawValue)/api').then(r => r.text());
              </script><p>Loaded through proxy</p>
              """
          }
          self.send(
            connection,
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: content-type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
          )
          self.read(connection, proxyHandshake: false, buffer: Data())
        }
      }
    }
  }

  private func send(_ connection: NWConnection, _ value: String) {
    connection.send(content: Data(value.utf8), completion: .contentProcessed { _ in })
  }
}

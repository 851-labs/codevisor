import AppKit
import CodevisorClient
import CodevisorUI
import Foundation
import Network
import OSLog
import Synchronization

/// A 0600 Unix socket in this installation's data namespace. It is never exposed
/// through the HTTP server, cloud relay, or a client on a different machine.
///
/// Threading: socket I/O, line framing, JSON, and per-session routing for every
/// client run on `queue`. The main actor owns the pane registry and is used only
/// where AppKit or CEF require it: CEF accepts commands only on its UI thread
/// (the main thread here) and delivers replies and events there, which are
/// copied and handed to `queue` in arrival order without being parsed. Page
/// commands and their (possibly multi-megabyte) results are forwarded as bytes,
/// with only the request `id` and `sessionId` rewritten.
@MainActor
final class ChromiumAutomationBridge {
  static let shared = ChromiumAutomationBridge()
  nonisolated static let queue = DispatchSerialQueue(label: "com.codevisor.browser-automation", qos: .userInitiated)
  private final class WeakModel {
    weak var value: ChromiumBrowserModel?; init(_ value: ChromiumBrowserModel) { self.value = value }
  }
  private final class WeakGroup {
    weak var value: PaneGroupModel?; init(_ value: PaneGroupModel) { self.value = value }
  }
  private var models: [String: WeakModel] = [:]
  private var groups: [WeakGroup] = []
  private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Codevisor", category: "BrowserAutomation")
  private var listener: NWListener?
  private var token = ""
  private nonisolated let hub = ChromiumAutomationHub()
  /// Models each connection controls, readable synchronously by page retention.
  nonisolated let controlled = Mutex<[UUID: Set<ObjectIdentifier>]>([:])

  func isControlling(_ model: ChromiumBrowserModel) -> Bool {
    let identifier = ObjectIdentifier(model)
    return controlled.withLock { $0.values.contains { $0.contains(identifier) } }
  }

  func addGroup(_ group: PaneGroupModel) {
    groups.removeAll { $0.value == nil }
    groups.append(WeakGroup(group))
    start()
  }
  func register(_ model: ChromiumBrowserModel) {
    guard model.isLocal else { return }
    let id = model.paneId.uuidString.lowercased()
    let created = models[id]?.value == nil
    models[id] = WeakModel(model)
    let hub = hub
    model.webView?.protocolEvent = { [weak model] message in
      guard let model else { return }
      Self.queue.async { hub.assumeIsolated { $0.event(message, model: model) } }
    }
    if created { broadcast(.targetCreated(info(model))) }
  }
  func unregister(_ id: UUID) {
    if models.removeValue(forKey: id.uuidString.lowercased()) != nil {
      broadcast(.targetDestroyed(id.uuidString.lowercased()))
    }
  }
  private func broadcast(_ event: ChromiumAutomationHub.TargetEvent) {
    let hub = hub
    Self.queue.async { hub.assumeIsolated { $0.broadcast(event) } }
  }
  fileprivate func info(_ model: ChromiumBrowserModel) -> ChromiumTargetInfo {
    ChromiumTargetInfo(
      targetId: model.paneId.uuidString.lowercased(), title: model.title,
      url: model.url?.absoluteString ?? "about:blank")
  }
  fileprivate func model(_ id: String) -> ChromiumBrowserModel? { models[id.lowercased()]?.value }
  fileprivate var liveModels: [ChromiumBrowserModel] { models.values.compactMap { $0.value } }
  fileprivate var targets: [ChromiumTargetInfo] { liveModels.map(info) }
  private func group(_ session: String) -> PaneGroupModel? {
    groups.compactMap { $0.value }.first { $0.canHostBrowserAutomation(sessionId: session) }
  }
  fileprivate func isAvailable(_ session: String) -> Bool { group(session) != nil }
  fileprivate func createTarget(session: String, url: String) -> ChromiumBrowserModel? {
    guard let model = group(session)?.createBrowserTab?(url) else { return nil }
    register(model)
    return model
  }
  fileprivate func activate(_ targetId: String) -> Bool {
    guard let model = model(targetId) else { return false }
    model.onSelect?()
    return true
  }
  fileprivate func close(_ targetId: String) -> Bool {
    guard let model = model(targetId) else { return false }
    model.onClose?()
    return true
  }
  /// Closes Browser Use tabs that never loaded a page. Tabs that did may be
  /// the agent's result, so they stay for the user.
  fileprivate func closeUnusedTabs(_ targetIds: [String]) {
    for targetId in targetIds {
      guard let model = model(targetId), !model.hasLoadedPage else { continue }
      model.onClose?()
    }
  }

  private func start() {
    guard listener == nil else { return }
    do {
      let directory = CodevisorAppVariant.serverDataDirectoryURL()
      let tokenURL = directory.appendingPathComponent("browser-use-token")
      if let existing = try? String(contentsOf: tokenURL, encoding: .utf8), !existing.isEmpty {
        token = existing
      } else {
        token = UUID().uuidString + UUID().uuidString
        try Data(token.utf8).write(to: tokenURL, options: .atomic)
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
      var hash: UInt32 = 2166136261
      for byte in directory.path.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
      let path = "/tmp/codevisor-browser-\(getuid())-\(String(hash, radix: 16)).sock"
      unlink(path)
      let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
      parameters.requiredLocalEndpoint = .unix(path: path)
      let server = try NWListener(using: parameters)
      let secret = token
      let hub = hub
      server.newConnectionHandler = { [weak self] connection in
        guard let self else { connection.cancel(); return }
        let client = ChromiumAutomationConnection(connection: connection, bridge: self, hub: hub, token: secret)
        hub.assumeIsolated { $0.add(client) }
        client.assumeIsolated { $0.start() }
      }
      server.stateUpdateHandler = { [weak self, weak server] state in
        Task { @MainActor [weak self, weak server] in
          guard let self, let server, self.listener === server else { return }
          if case .ready = state { chmod(path, 0o600) }
          if case .failed(let error) = state {
            self.log.error("Local browser listener failed: \(error.localizedDescription, privacy: .public)")
            server.cancel()
            self.listener = nil
          }
        }
      }
      listener = server
      server.start(queue: Self.queue)
    } catch {
      log.error("Couldn’t start local browser automation: \(error.localizedDescription, privacy: .public)")
    }
  }
}

nonisolated struct ChromiumTargetInfo: Sendable {
  var targetId: String
  var title: String
  var url: String
  var json: [String: Any] { ["targetId": targetId, "type": "page", "title": title, "url": url, "attached": false] }
}

extension ChromiumBrowserModel {
  /// Viewport emulation goes through the pane so its scaled host view follows
  /// the page. These commands are small; their params are decoded here.
  fileprivate func automationViewport(_ method: String, params: Data?) async throws -> Data {
    let params = params.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    switch method {
    case "Emulation.setDeviceMetricsOverride":
      try await setViewport(params)
      return Data("{}".utf8)
    case "Emulation.clearDeviceMetricsOverride":
      try await resetViewport()
      return Data("{}".utf8)
    default:
      let result = try await readyView().cdp(method, params)
      viewport?.touch = params["enabled"] as? Bool ?? false
      return try JSONSerialization.data(withJSONObject: result)
    }
  }
}

/// Every connection, confined to the automation queue. Each browser event is
/// scanned once here, then routed by each connection.
private actor ChromiumAutomationHub {
  nonisolated enum TargetEvent: Sendable {
    case targetCreated(ChromiumTargetInfo)
    case targetDestroyed(String)
  }
  nonisolated var unownedExecutor: UnownedSerialExecutor { ChromiumAutomationBridge.queue.asUnownedSerialExecutor() }
  private var connections: [UUID: ChromiumAutomationConnection] = [:]

  func add(_ connection: ChromiumAutomationConnection) { connections[connection.id] = connection }
  func remove(_ id: UUID) { connections[id] = nil }

  func event(_ data: Data, model: ChromiumBrowserModel) {
    guard !connections.isEmpty, let message = BrowserProtocolMessage(data), let method = message.string("method")
    else { return }
    for connection in connections.values {
      connection.assumeIsolated { $0.event(message, method: method, model: model) }
    }
  }

  func broadcast(_ event: TargetEvent) {
    let message: [String: Any] =
      switch event {
      case .targetCreated(let info): ["method": "Target.targetCreated", "params": ["targetInfo": info.json]]
      case .targetDestroyed(let id): ["method": "Target.targetDestroyed", "params": ["targetId": id]]
      }
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    for connection in connections.values {
      connection.assumeIsolated { if $0.authenticated { $0.send(data) } }
    }
  }
}

/// One validated request line. Only the routing members are decoded; page
/// commands forward `params` as the client's bytes.
private nonisolated struct ChromiumAutomationRequest {
  var id: Data
  var method: String?
  var sessionId: String?
  var params: [String: Any]
  var rawParams: Data?

  init?(_ line: Data) {
    // A full parse rejects malformed requests, as CEF would drop them silently.
    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      let message = BrowserProtocolMessage(line)
    else { return nil }
    id = message.raw("id") ?? Data("0".utf8)
    method = object["method"] as? String
    sessionId = object["sessionId"] as? String
    params = object["params"] as? [String: Any] ?? [:]
    rawParams = object["params"] is [String: Any] ? message.raw("params") : nil
  }
}

private actor ChromiumAutomationConnection {
  private nonisolated struct Attachment {
    var model: ChromiumBrowserModel
    var native: String
    var popup: Bool
  }
  private static let browserMethods: Set<String> = [
    "Target.getTargets", "Target.createTarget", "Target.activateTarget", "Target.closeTarget",
    "Target.attachToTarget", "Target.detachFromTarget", "Browser.close",
  ]
  private static let viewportMethods: Set<String> = [
    "Emulation.setDeviceMetricsOverride", "Emulation.clearDeviceMetricsOverride", "Emulation.setTouchEmulationEnabled",
  ]
  private static let lineLimit = 64 * 1024 * 1024

  nonisolated let id = UUID()
  nonisolated var unownedExecutor: UnownedSerialExecutor { ChromiumAutomationBridge.queue.asUnownedSerialExecutor() }
  private let connection: NWConnection
  private let bridge: ChromiumAutomationBridge
  private let hub: ChromiumAutomationHub
  private let token: String
  private var lines = BrowserProtocolLineBuffer()
  private(set) var authenticated = false
  private var session = ""
  private var sessions: [String: Attachment] = [:] {
    didSet { publishControl() }
  }
  private var nativeOwners: [String: ChromiumBrowserModel] = [:]
  private var popupOwners: [String: ChromiumBrowserModel] = [:] {
    didSet { publishControl() }
  }
  private var childSessions: [String: ChromiumBrowserModel] = [:]
  /// Tabs this agent connection opened. When the connection ends without the
  /// server closing them (a server restart or crash), blank ones are closed.
  private var createdTabs: [String] = []
  private var closed = false

  init(connection: NWConnection, bridge: ChromiumAutomationBridge, hub: ChromiumAutomationHub, token: String) {
    self.connection = connection; self.bridge = bridge; self.hub = hub; self.token = token
  }

  private func publishControl() {
    let id = id
    let models =
      closed
      ? nil : Set(sessions.values.map { ObjectIdentifier($0.model) } + popupOwners.values.map(ObjectIdentifier.init))
    bridge.controlled.withLock { $0[id] = models }
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.assumeIsolated { $0.close() }
      default: break
      }
    }
    connection.start(queue: ChromiumAutomationBridge.queue)
    receive()
  }
  private func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    for attached in sessions.values {
      let model = attached.model, native = attached.native
      Task { @MainActor in _ = try? await model.webView?.cdp("Target.detachFromTarget", ["sessionId": native]) }
    }
    sessions.removeAll(); childSessions.removeAll()
    let created = createdTabs, bridge = bridge
    createdTabs.removeAll()
    if !created.isEmpty { Task { @MainActor in bridge.closeUnusedTabs(created) } }
    hub.assumeIsolated { $0.remove(id) }
  }
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
      self?.assumeIsolated { $0.didReceive(data, ended: ended || error != nil) }
    }
  }
  private func didReceive(_ data: Data?, ended: Bool) {
    guard !closed else { return }
    for line in lines.append(data ?? Data()) {
      guard let request = ChromiumAutomationRequest(line) else { close(); return }
      handle(request)
    }
    if lines.pendingCount > Self.lineLimit || ended { close() } else { receive() }
  }

  func send(_ data: Data) {
    guard !closed else { return }
    var line = data
    line.append(0x0A)
    connection.send(content: line, completion: .contentProcessed { _ in })
  }
  private func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    send(data)
  }
  private func reply(_ id: Data, error message: String) {
    let error = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data("{}".utf8)
    send(BrowserProtocolMessage.response(id: id, error: error))
  }
  private func reply(_ id: Data, result: [String: Any]) {
    send(BrowserProtocolMessage.response(id: id, result: try? JSONSerialization.data(withJSONObject: result)))
  }

  private func handle(_ request: ChromiumAutomationRequest) {
    guard let method = request.method else { return reply(request.id, error: "Missing browser method") }
    let params = request.params
    if !authenticated {
      guard method == "Codevisor.connect", params["token"] as? String == token,
        let session = params["sessionId"] as? String
      else { return reply(request.id, error: "Authentication failed") }
      self.session = session; authenticated = true
      let bridge = bridge, id = request.id
      Task { reply(id, result: ["available": await bridge.isAvailable(session)]) }
      return
    }
    if let sessionId = request.sessionId, !Self.browserMethods.contains(method) {
      guard let model = sessions[sessionId]?.model ?? childSessions[sessionId] else {
        return reply(request.id, error: "Unknown browser session")
      }
      if method.hasPrefix("Target."), !["Target.setAutoAttach", "Target.getTargetInfo"].contains(method) {
        return reply(request.id, error: "This target operation is unavailable in the built-in browser")
      }
      if method == "Target.getTargetInfo", params["targetId"] != nil {
        return reply(request.id, error: "Only this browser session's target is available")
      }
      if sessions[sessionId]?.popup == false, Self.viewportMethods.contains(method) {
        let id = request.id, raw = request.rawParams
        Task {
          do {
            let result = try await model.automationViewport(method, params: raw)
            send(BrowserProtocolMessage.response(id: id, result: result))
          } catch { reply(id, error: error.localizedDescription) }
        }
        return
      }
      return forward(
        request.id, method, request.rawParams, to: model, session: sessions[sessionId]?.native ?? sessionId)
    }
    let id = request.id
    Task {
      do { reply(id, result: try await dispatch(method, params)) } catch {
        reply(id, error: error.localizedDescription)
      }
    }
  }

  /// Requests reach CEF in arrival order: each hop is FIFO (this queue, then
  /// the main actor), and replies return through `queue` in CEF's order.
  private func forward(_ id: Data, _ method: String, _ params: Data?, to model: ChromiumBrowserModel, session: String) {
    let connection = self
    Task { @MainActor in
      do {
        try await model.readyView().sendProtocolMethod(method, params: params, sessionId: session) { reply in
          ChromiumAutomationBridge.queue.async { connection.assumeIsolated { $0.forwardReply(id, reply) } }
        }
      } catch {
        let message = error.localizedDescription
        ChromiumAutomationBridge.queue.async { connection.assumeIsolated { $0.reply(id, error: message) } }
      }
    }
  }
  private func forwardReply(_ id: Data, _ reply: Data) {
    guard let message = BrowserProtocolMessage(reply) else { return self.reply(id, error: "Invalid browser reply") }
    if let error = message.raw("error") {
      send(BrowserProtocolMessage.response(id: id, error: error))
    } else {
      send(BrowserProtocolMessage.response(id: id, result: message.raw("result")))
    }
  }

  private func dispatch(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
    switch method {
    case "Codevisor.synchronizeCookies":
      for model in await bridge.liveModels { try await model.synchronizeCookies() }
      return [:]
    case "Target.setDiscoverTargets":
      if params["discover"] as? Bool == true { _ = try await targets() }
      return [:]
    case "Target.getTargets": return ["targetInfos": try await targets()]
    case "Target.createTarget":
      guard let model = await bridge.createTarget(session: session, url: params["url"] as? String ?? "about:blank")
      else { throw ChromiumProtocolError("This workspace is no longer open in Codevisor") }
      let targetId = model.paneId.uuidString.lowercased()
      createdTabs.append(targetId)
      do {
        _ = try await model.readyView()
      } catch {
        // The agent never learns this tab's id, so nothing else would close it.
        await bridge.closeUnusedTabs([targetId])
        throw error
      }
      return ["targetId": targetId]
    case "Target.activateTarget":
      let targetId = params["targetId"] as? String ?? ""
      if let owner = popupOwners[targetId] { return try await owner.readyView().cdp(method, params) }
      guard await bridge.activate(targetId) else { throw ChromiumProtocolError("Browser tab closed") }
      return [:]
    case "Target.closeTarget":
      let targetId = params["targetId"] as? String ?? ""
      if let owner = popupOwners[targetId] { return try await owner.readyView().cdp(method, params) }
      return ["success": await bridge.close(targetId)]
    case "Target.attachToTarget":
      let targetId = params["targetId"] as? String ?? ""
      let popup = popupOwners[targetId] != nil
      guard let model = await bridge.model(targetId) ?? popupOwners[targetId] else {
        throw ChromiumProtocolError("Browser tab closed")
      }
      let view = try await model.readyView()
      let target = try await view.cdp("Target.getTargetInfo")
      guard let info = target["targetInfo"] as? [String: Any], let nativeTarget = info["targetId"] as? String else {
        throw ChromiumProtocolError("Missing browser target")
      }
      let result = try await view.cdp(
        "Target.attachToTarget", ["targetId": popup ? targetId : nativeTarget, "flatten": true])
      guard let native = result["sessionId"] as? String else { throw ChromiumProtocolError("Couldn’t attach browser") }
      let sessionId = UUID().uuidString
      sessions[sessionId] = Attachment(model: model, native: native, popup: popup)
      return ["sessionId": sessionId]
    case "Target.detachFromTarget":
      if let key = params["sessionId"] as? String, let attached = sessions.removeValue(forKey: key) {
        _ = try await attached.model.webView?.cdp(method, ["sessionId": attached.native])
      }
      return [:]
    case "Browser.getVersion": return ["product": "Codevisor/Chromium", "protocolVersion": "1.3"]
    case "Browser.close": throw ChromiumProtocolError("Automation cannot quit the Codevisor app")
    default:
      guard method == "Browser.setDownloadBehavior" else {
        throw ChromiumProtocolError("Attach a browser tab before using this protocol method")
      }
      guard let model = sessions.values.first?.model else { throw ChromiumProtocolError("Attach a browser tab first") }
      return try await model.readyView().cdp(method, params)
    }
  }
  private func targets() async throws -> [[String: Any]] {
    let models = await bridge.liveModels
    // One tab that can't start must not fail every agent's browser call. It is
    // still listed, and attaching to it reports its own error.
    var ready: CVChromiumView?
    var failure: Error?
    for model in models {
      do {
        let view = try await model.readyView()
        let response = try await view.cdp("Target.getTargetInfo")
        if let info = response["targetInfo"] as? [String: Any], let id = info["targetId"] as? String {
          nativeOwners[id] = model
        }
        _ = try await view.cdp("Target.setDiscoverTargets", ["discover": true])
        ready = ready ?? view
      } catch {
        failure = failure ?? error
      }
    }
    guard !models.isEmpty else { return [] }
    guard let ready else { throw failure ?? ChromiumProtocolError("Browser tab closed") }
    let all = try await ready.cdp("Target.getTargets")
    let infos = all["targetInfos"] as? [[String: Any]] ?? []
    // Only include popups whose opener descends from an admitted local pane.
    // Other CEF profiles (remote workspaces and the DevTools frontend) stay private.
    var changed = true
    while changed {
      changed = false
      for info in infos {
        guard info["type"] as? String == "page", let id = info["targetId"] as? String,
          nativeOwners[id] == nil, let opener = info["openerId"] as? String, let owner = nativeOwners[opener]
        else { continue }
        nativeOwners[id] = owner; popupOwners[id] = owner; changed = true
      }
    }
    let live = Set(infos.compactMap { $0["targetId"] as? String })
    popupOwners = popupOwners.filter { live.contains($0.key) }
    return (await bridge.targets).map(\.json)
      + infos.filter { ($0["targetId"] as? String).flatMap { popupOwners[$0] } != nil }.map(popupInfo)
  }
  private func popupInfo(_ info: [String: Any]) -> [String: Any] {
    var result = info
    if let opener = info["openerId"] as? String, popupOwners[opener] == nil, let owner = nativeOwners[opener] {
      result["openerId"] = owner.paneId.uuidString.lowercased()
    }
    return result
  }

  /// Routes one browser event. Session events are forwarded as their bytes with
  /// only `sessionId` rewritten; only small Target events are decoded.
  func event(_ message: BrowserProtocolMessage, method: String, model: ChromiumBrowserModel) {
    guard authenticated else { return }
    guard let native = message.string("sessionId") else {
      let params = message.object("params") ?? [:]
      if ["Target.targetCreated", "Target.targetInfoChanged"].contains(method),
        let info = params["targetInfo"] as? [String: Any],
        info["type"] as? String == "page", let target = info["targetId"] as? String,
        let opener = info["openerId"] as? String, nativeOwners[opener] === model
      {
        let created = popupOwners[target] == nil
        nativeOwners[target] = model; popupOwners[target] = model
        send(["method": created ? "Target.targetCreated" : method, "params": ["targetInfo": popupInfo(info)]])
      } else if method == "Target.targetDestroyed", let target = params["targetId"] as? String,
        popupOwners.removeValue(forKey: target) != nil
      {
        nativeOwners[target] = nil; send(message.data)
      }
      return
    }
    var forwarded = message.data
    if let attached = sessions.first(where: { $0.value.model === model && $0.value.native == native }) {
      forwarded = message.setting("sessionId", to: BrowserProtocolMessage.encode(attached.key))
    } else if childSessions[native] !== model {
      return
    }
    if method == "Target.attachedToTarget" || method == "Target.detachedFromTarget",
      let child = message.object("params")?["sessionId"] as? String
    {
      childSessions[child] = method == "Target.attachedToTarget" ? model : nil
    }
    send(forwarded)
  }
}

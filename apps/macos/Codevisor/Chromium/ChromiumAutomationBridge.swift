import AppKit
import CodevisorClient
import Foundation
import Network
import OSLog

/// A 0600 Unix socket in this installation's data namespace. It is never exposed
/// through the HTTP server, cloud relay, or a client on a different machine.
@MainActor
final class ChromiumAutomationBridge {
  static let shared = ChromiumAutomationBridge()
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
  private var connections: [UUID: ChromiumAutomationConnection] = [:]
  private var token = ""

  func isControlling(_ model: ChromiumBrowserModel) -> Bool {
    connections.values.contains { $0.controls(model) }
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
    model.webView?.protocolEvent = { [weak self, weak model] json in
      guard let self, let model else { return }
      for connection in self.connections.values { connection.event(json, model: model) }
    }
    if created { broadcast("Target.targetCreated", ["targetInfo": info(model)]) }
  }
  func unregister(_ id: UUID) {
    if models.removeValue(forKey: id.uuidString.lowercased()) != nil {
      broadcast("Target.targetDestroyed", ["targetId": id.uuidString.lowercased()])
    }
  }
  private func broadcast(_ method: String, _ params: [String: Any]) {
    for connection in connections.values where connection.authenticated {
      connection.send(["method": method, "params": params])
    }
  }
  fileprivate func info(_ model: ChromiumBrowserModel) -> [String: Any] {
    [
      "targetId": model.paneId.uuidString.lowercased(), "type": "page", "title": model.title,
      "url": model.url?.absoluteString ?? "about:blank", "attached": false,
    ]
  }
  fileprivate func model(_ id: String) -> ChromiumBrowserModel? { models[id.lowercased()]?.value }
  fileprivate var liveModels: [ChromiumBrowserModel] { models.values.compactMap { $0.value } }
  fileprivate var targets: [[String: Any]] { liveModels.map(info) }
  fileprivate func group(_ session: String) -> PaneGroupModel? {
    groups.compactMap { $0.value }.first { $0.canHostBrowserAutomation(sessionId: session) }
  }
  fileprivate func remove(_ id: UUID) { connections[id] = nil }

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
      server.newConnectionHandler = { [weak self] connection in
        Task { @MainActor [weak self] in
          guard let self else { connection.cancel(); return }
          let client = ChromiumAutomationConnection(connection: connection, bridge: self, token: secret)
          self.connections[client.id] = client
          client.start()
        }
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
      server.start(queue: .main)
    } catch {
      log.error("Couldn’t start local browser automation: \(error.localizedDescription, privacy: .public)")
    }
  }
}

@MainActor
private final class ChromiumAutomationConnection {
  let id = UUID()
  private let connection: NWConnection
  private unowned let bridge: ChromiumAutomationBridge
  private let token: String
  private var buffer = Data()
  fileprivate var authenticated = false
  private var session = ""
  private var sessions: [String: (model: ChromiumBrowserModel, native: String, popup: Bool)] = [:]
  private var nativeOwners: [String: ChromiumBrowserModel] = [:]
  private var popupOwners: [String: ChromiumBrowserModel] = [:]
  private var childSessions: [String: ChromiumBrowserModel] = [:]
  private var closed = false

  func controls(_ model: ChromiumBrowserModel) -> Bool {
    !closed
      && (sessions.values.contains { $0.model === model }
        || popupOwners.values.contains { $0 === model })
  }

  init(connection: NWConnection, bridge: ChromiumAutomationBridge, token: String) {
    self.connection = connection; self.bridge = bridge; self.token = token
  }
  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state { Task { @MainActor [weak self] in self?.close() } }
      if case .cancelled = state { Task { @MainActor [weak self] in self?.close() } }
    }
    connection.start(queue: .main)
    receive()
  }
  private func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    for (_, attached) in sessions {
      Task { _ = try? await attached.model.webView?.cdp("Target.detachFromTarget", ["sessionId": attached.native]) }
    }
    sessions.removeAll(); childSessions.removeAll()
    bridge.remove(id)
  }
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
      Task { @MainActor [weak self] in
        guard let self, !self.closed else { return }
        if let data { self.buffer.append(data) }
        if self.buffer.count > 64 * 1024 * 1024 { self.close(); return }
        while let newline = self.buffer.firstIndex(of: 10) {
          let line = self.buffer.prefix(upTo: newline)
          self.buffer.removeSubrange(...newline)
          guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            self.close(); return
          }
          Task { await self.handle(message) }
        }
        if ended || error != nil { self.close() } else { self.receive() }
      }
    }
  }
  func send(_ message: [String: Any]) {
    guard !closed, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    connection.send(content: data + Data([10]), completion: .contentProcessed { _ in })
  }
  private func handle(_ message: [String: Any]) async {
    let requestId = message["id"] ?? 0
    do {
      guard let method = message["method"] as? String else { throw ChromiumProtocolError("Missing browser method") }
      let params = message["params"] as? [String: Any] ?? [:]
      if !authenticated {
        guard method == "Codevisor.connect", params["token"] as? String == token,
          let session = params["sessionId"] as? String
        else { throw ChromiumProtocolError("Authentication failed") }
        self.session = session; authenticated = true
        send(["id": requestId, "result": ["available": bridge.group(session) != nil]])
        return
      }
      let result = try await dispatch(method, params, message["sessionId"] as? String)
      send(["id": requestId, "result": result])
    } catch { send(["id": requestId, "error": ["message": error.localizedDescription]]) }
  }
  private func dispatch(_ method: String, _ params: [String: Any], _ sessionId: String?) async throws -> [String: Any] {
    if sessionId != nil,
      [
        "Target.getTargets", "Target.createTarget", "Target.activateTarget", "Target.closeTarget",
        "Target.attachToTarget", "Target.detachFromTarget", "Browser.close",
      ].contains(method)
    {
      return try await dispatch(method, params, nil)
    }
    if let sessionId {
      guard let model = sessions[sessionId]?.model ?? childSessions[sessionId] else {
        throw ChromiumProtocolError("Unknown browser session")
      }
      if method.hasPrefix("Target."), !["Target.setAutoAttach", "Target.getTargetInfo"].contains(method) {
        throw ChromiumProtocolError("This target operation is unavailable in the built-in browser")
      }
      if method == "Target.getTargetInfo", params["targetId"] != nil {
        throw ChromiumProtocolError("Only this browser session's target is available")
      }
      let native = sessions[sessionId]?.native ?? sessionId
      let view = try await model.readyView()
      if method == "Emulation.setDeviceMetricsOverride", sessions[sessionId]?.popup == false {
        try await model.setViewport(params); return [:]
      }
      if method == "Emulation.clearDeviceMetricsOverride", sessions[sessionId]?.popup == false {
        try await model.resetViewport(); return [:]
      }
      if method == "Emulation.setTouchEmulationEnabled", sessions[sessionId]?.popup == false {
        let result = try await view.cdp(method, params)
        model.viewport?.touch = params["enabled"] as? Bool ?? false
        return result
      }
      return try await view.cdp(method, params, sessionId: native)
    }
    switch method {
    case "Codevisor.synchronizeCookies":
      for model in bridge.liveModels { try await model.synchronizeCookies() }
      return [:]
    case "Target.setDiscoverTargets":
      if params["discover"] as? Bool == true { _ = try await targets() }
      return [:]
    case "Target.getTargets": return ["targetInfos": try await targets()]
    case "Target.createTarget":
      guard let group = bridge.group(session),
        let model = group.createBrowserTab?(params["url"] as? String ?? "about:blank")
      else { throw ChromiumProtocolError("This workspace is no longer open in Codevisor") }
      bridge.register(model)
      _ = try await model.readyView()
      return ["targetId": model.paneId.uuidString.lowercased()]
    case "Target.activateTarget":
      let targetId = params["targetId"] as? String ?? ""
      if let owner = popupOwners[targetId] { return try await owner.readyView().cdp(method, params) }
      guard let model = bridge.model(targetId) else { throw ChromiumProtocolError("Browser tab closed") }
      model.onSelect?(); return [:]
    case "Target.closeTarget":
      let targetId = params["targetId"] as? String ?? ""
      if let owner = popupOwners[targetId] { return try await owner.readyView().cdp(method, params) }
      guard let model = bridge.model(targetId) else { return ["success": false] }
      model.onClose?(); return ["success": true]
    case "Target.attachToTarget":
      let targetId = params["targetId"] as? String ?? ""
      let popup = popupOwners[targetId] != nil
      guard let model = bridge.model(targetId) ?? popupOwners[targetId] else {
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
      sessions[sessionId] = (model, native, popup)
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
    let models = bridge.liveModels
    for model in models {
      let view = try await model.readyView()
      let response = try await view.cdp("Target.getTargetInfo")
      if let info = response["targetInfo"] as? [String: Any], let id = info["targetId"] as? String {
        nativeOwners[id] = model
      }
      _ = try await view.cdp("Target.setDiscoverTargets", ["discover": true])
    }
    guard let first = models.first else { return [] }
    let all = try await first.readyView().cdp("Target.getTargets")
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
    return bridge.targets
      + infos.filter { ($0["targetId"] as? String).flatMap { popupOwners[$0] } != nil }.map(popupInfo)
  }
  private func popupInfo(_ info: [String: Any]) -> [String: Any] {
    var result = info
    if let opener = info["openerId"] as? String, popupOwners[opener] == nil, let owner = nativeOwners[opener] {
      result["openerId"] = owner.paneId.uuidString.lowercased()
    }
    return result
  }
  func event(_ json: String, model: ChromiumBrowserModel) {
    guard authenticated, var message = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
      message["method"] is String
    else { return }
    guard let native = message["sessionId"] as? String else {
      let method = message["method"] as? String ?? ""
      let params = message["params"] as? [String: Any] ?? [:]
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
        nativeOwners[target] = nil; send(message)
      }
      return
    }
    if let attached = sessions.first(where: { $0.value.model === model && $0.value.native == native }) {
      message["sessionId"] = attached.key
    } else if childSessions[native] !== model {
      return
    }
    if message["method"] as? String == "Target.attachedToTarget", let params = message["params"] as? [String: Any],
      let child = params["sessionId"] as? String
    {
      childSessions[child] = model
    }
    if message["method"] as? String == "Target.detachedFromTarget", let params = message["params"] as? [String: Any],
      let child = params["sessionId"] as? String
    {
      childSessions[child] = nil
    }
    send(message)
  }
}

import AppKit
import CodevisorClient
import CodevisorUI
import Foundation
import Synchronization

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
  private final class WeakStore {
    weak var value: SessionStore?; init(_ value: SessionStore) { self.value = value }
  }
  private var models: [String: WeakModel] = [:]
  private var groups: [WeakGroup] = []
  private var stores: [WeakStore] = []
  nonisolated let hub = ChromiumAutomationHub()
  nonisolated let controlled = Mutex<[UUID: Set<ObjectIdentifier>]>([:])
  let hosts = ChromiumBrowserHosts()

  func isControlling(_ model: ChromiumBrowserModel) -> Bool {
    let identifier = ObjectIdentifier(model)
    return controlled.withLock { $0.values.contains { $0.contains(identifier) } }
  }

  func addGroup(_ group: PaneGroupModel) {
    groups.removeAll { $0.value == nil }
    groups.append(WeakGroup(group))
  }
  func addStore(_ store: SessionStore) {
    stores.removeAll { $0.value == nil }
    stores.append(WeakStore(store))
  }
  func register(_ model: ChromiumBrowserModel) {
    let id = model.paneId.uuidString.lowercased()
    let created = models[id]?.value == nil
    models[id] = WeakModel(model)
    let hub = hub
    model.webView?.protocolEvent = { [weak model] message in
      guard let model else { return }
      Self.queue.async { hub.assumeIsolated { $0.event(message, model: model) } }
    }
    if created { broadcast(.targetCreated(info(model), machineId: model.machineId)) }
  }
  func unregister(_ id: UUID) {
    if let model = models.removeValue(forKey: id.uuidString.lowercased())?.value {
      broadcast(.targetDestroyed(id.uuidString.lowercased(), machineId: model.machineId))
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
  fileprivate func model(_ id: String, machineId: String) -> ChromiumBrowserModel? {
    models[id.lowercased()]?.value.flatMap { $0.machineId == machineId ? $0 : nil }
  }
  fileprivate func liveModels(machineId: String) -> [ChromiumBrowserModel] {
    models.values.compactMap { $0.value }.filter { $0.machineId == machineId }
  }
  fileprivate func targets(machineId: String) -> [ChromiumTargetInfo] {
    liveModels(machineId: machineId).map(info)
  }
  private func group(_ session: String, machineId: String) -> PaneGroupModel? {
    groups.compactMap { $0.value }.first {
      $0.canHostBrowserAutomation(sessionId: session, machineId: machineId)
    }
  }
  private var store: SessionStore? {
    stores.removeAll { $0.value == nil }
    return stores.lazy.compactMap(\.value).first { $0.isWindowFocused } ?? stores.first?.value
  }
  fileprivate func isAvailable(_ session: String, machineId: String) -> Bool {
    group(session, machineId: machineId) != nil
      || store?.canHostBackgroundBrowser(serverId: machineId, sessionId: session) == true
  }
  fileprivate func createTarget(session: String, machineId: String, url: String) -> ChromiumBrowserModel? {
    let created =
      group(session, machineId: machineId)?.createBrowserTab?(url)
      ?? store?.createBackgroundBrowserTab(serverId: machineId, sessionId: session, url: url)
    guard let created else { return nil }
    register(created)
    return created
  }
  fileprivate func activate(_ targetId: String, machineId: String) -> Bool {
    guard let model = model(targetId, machineId: machineId) else { return false }
    model.onSelect?()
    return true
  }
  fileprivate func close(_ targetId: String, machineId: String) -> Bool {
    guard let model = model(targetId, machineId: machineId) else { return false }
    model.onClose?()
    return true
  }
  fileprivate func closeUnusedTabs(_ targetIds: [String], machineId: String) {
    for targetId in targetIds {
      guard let model = model(targetId, machineId: machineId), !model.hasLoadedPage else { continue }
      model.onClose?()
    }
  }

  func openChannel(
    _ channel: String, machineId: String, outbox: @escaping @Sendable (ChromiumBrowserHostFrame) -> Void
  ) -> ChromiumAutomationConnection {
    let connection = ChromiumAutomationConnection(
      channel: channel, machineId: machineId, bridge: self, hub: hub, outbox: outbox)
    let hub = hub
    Self.queue.async { hub.assumeIsolated { $0.add(connection) } }
    return connection
  }
}

nonisolated struct ChromiumTargetInfo: Sendable {
  var targetId: String
  var title: String
  var url: String
  var json: [String: Any] { ["targetId": targetId, "type": "page", "title": title, "url": url, "attached": false] }
}

extension ChromiumBrowserModel {
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

actor ChromiumAutomationHub {
  nonisolated enum TargetEvent: Sendable {
    case targetCreated(ChromiumTargetInfo, machineId: String)
    case targetDestroyed(String, machineId: String)
  }
  nonisolated var unownedExecutor: UnownedSerialExecutor { ChromiumAutomationBridge.queue.asUnownedSerialExecutor() }
  private var connections: [UUID: ChromiumAutomationConnection] = [:]

  func add(_ connection: ChromiumAutomationConnection) { connections[connection.id] = connection }
  func remove(_ id: UUID) { connections[id] = nil }

  func event(_ data: Data, model: ChromiumBrowserModel) {
    guard !connections.isEmpty, let message = BrowserProtocolMessage(data), let method = message.string("method")
    else { return }
    let machineId = model.machineId
    for connection in connections.values where connection.machineId == machineId {
      connection.assumeIsolated { $0.event(message, method: method, model: model) }
    }
  }

  func broadcast(_ event: TargetEvent) {
    let (message, machineId): ([String: Any], String) =
      switch event {
      case .targetCreated(let info, let machineId):
        (["method": "Target.targetCreated", "params": ["targetInfo": info.json]], machineId)
      case .targetDestroyed(let id, let machineId):
        (["method": "Target.targetDestroyed", "params": ["targetId": id]], machineId)
      }
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    for connection in connections.values where connection.machineId == machineId {
      connection.assumeIsolated { if $0.authenticated { $0.send(data) } }
    }
  }
}

private nonisolated struct ChromiumAutomationRequest {
  var id: Data
  var method: String?
  var sessionId: String?
  var params: [String: Any]
  var rawParams: Data?

  init?(_ line: Data) {
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

actor ChromiumAutomationConnection {
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
  nonisolated let id = UUID()
  nonisolated let channel: String
  nonisolated let machineId: String
  nonisolated var unownedExecutor: UnownedSerialExecutor { ChromiumAutomationBridge.queue.asUnownedSerialExecutor() }
  private let bridge: ChromiumAutomationBridge
  private let hub: ChromiumAutomationHub
  private let outbox: @Sendable (ChromiumBrowserHostFrame) -> Void
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
  private var createdTabs: [String] = []
  private var closed = false

  init(
    channel: String, machineId: String, bridge: ChromiumAutomationBridge, hub: ChromiumAutomationHub,
    outbox: @escaping @Sendable (ChromiumBrowserHostFrame) -> Void
  ) {
    self.channel = channel; self.machineId = machineId; self.bridge = bridge; self.hub = hub; self.outbox = outbox
  }

  private func publishControl() {
    let id = id
    let models =
      closed
      ? nil : Set(sessions.values.map { ObjectIdentifier($0.model) } + popupOwners.values.map(ObjectIdentifier.init))
    bridge.controlled.withLock { $0[id] = models }
  }

  func close(notifyingHost: Bool = true) {
    guard !closed else { return }
    closed = true
    if notifyingHost { outbox(.close(channel: channel)) }
    for attached in sessions.values {
      let model = attached.model, native = attached.native
      Task { @MainActor in _ = try? await model.webView?.cdp("Target.detachFromTarget", ["sessionId": native]) }
    }
    sessions.removeAll(); childSessions.removeAll()
    let created = createdTabs, bridge = bridge, machineId = machineId
    createdTabs.removeAll()
    if !created.isEmpty { Task { @MainActor in bridge.closeUnusedTabs(created, machineId: machineId) } }
    hub.assumeIsolated { $0.remove(id) }
  }
  func receive(_ data: Data) {
    guard !closed else { return }
    guard let request = ChromiumAutomationRequest(data) else { return close() }
    handle(request)
  }

  func send(_ data: Data) {
    guard !closed else { return }
    outbox(.data(channel: channel, payload: data))
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
      guard method == "Codevisor.connect", let session = params["sessionId"] as? String
      else { return reply(request.id, error: "Connect a chat before using the browser") }
      self.session = session; authenticated = true
      let bridge = bridge, id = request.id, machineId = machineId
      Task { reply(id, result: ["available": await bridge.isAvailable(session, machineId: machineId)]) }
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
      for model in await bridge.liveModels(machineId: machineId) { try await model.synchronizeCookies() }
      return [:]
    case "Target.setDiscoverTargets":
      if params["discover"] as? Bool == true { _ = try await targets() }
      return [:]
    case "Target.getTargets": return ["targetInfos": try await targets()]
    case "Target.createTarget":
      guard
        let model = await bridge.createTarget(
          session: session, machineId: machineId, url: params["url"] as? String ?? "about:blank")
      else { throw ChromiumProtocolError("This chat isn't available in the Codevisor app") }
      let targetId = model.paneId.uuidString.lowercased()
      createdTabs.append(targetId)
      do {
        _ = try await model.readyView()
      } catch {
        await bridge.closeUnusedTabs([targetId], machineId: machineId)
        throw error
      }
      return ["targetId": targetId]
    case "Target.activateTarget":
      let targetId = params["targetId"] as? String ?? ""
      if let owner = popupOwners[targetId] { return try await owner.readyView().cdp(method, params) }
      guard await bridge.activate(targetId, machineId: machineId) else {
        throw ChromiumProtocolError("Browser tab closed")
      }
      return [:]
    case "Target.closeTarget":
      let targetId = params["targetId"] as? String ?? ""
      if let owner = popupOwners[targetId] { return try await owner.readyView().cdp(method, params) }
      return ["success": await bridge.close(targetId, machineId: machineId)]
    case "Target.attachToTarget":
      let targetId = params["targetId"] as? String ?? ""
      let popup = popupOwners[targetId] != nil
      guard let model = await bridge.model(targetId, machineId: machineId) ?? popupOwners[targetId] else {
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
    let models = await bridge.liveModels(machineId: machineId)
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
    return (await bridge.targets(machineId: machineId)).map(\.json)
      + infos.filter { ($0["targetId"] as? String).flatMap { popupOwners[$0] } != nil }.map(popupInfo)
  }
  private func popupInfo(_ info: [String: Any]) -> [String: Any] {
    var result = info
    if let opener = info["openerId"] as? String, popupOwners[opener] == nil, let owner = nativeOwners[opener] {
      result["openerId"] = owner.paneId.uuidString.lowercased()
    }
    return result
  }

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

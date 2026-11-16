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
  func downloadUpdated(_ download: CVChromiumDownload, in model: ChromiumBrowserModel) {
    guard isControlling(model) else { return }

    let update = ChromiumAutomationDownload(download)
    let hub = hub
    Self.queue.async { hub.assumeIsolated { $0.download(update, model: model) } }
  }
  private func broadcast(_ event: ChromiumAutomationHub.TargetEvent) {
    let hub = hub
    Self.queue.async { hub.assumeIsolated { $0.broadcast(event) } }
  }
  func info(_ model: ChromiumBrowserModel) -> ChromiumTargetInfo {
    ChromiumTargetInfo(
      targetId: model.paneId.uuidString.lowercased(), title: model.title,
      url: model.url?.absoluteString ?? "about:blank", openerId: model.openerPaneId?.uuidString.lowercased())
  }
  func popupTabs(openedBy opener: ChromiumBrowserModel) -> [ChromiumBrowserModel] {
    liveModels(machineId: opener.machineId).filter { $0.openerPaneId == opener.paneId }
  }
  func model(_ id: String, machineId: String) -> ChromiumBrowserModel? {
    models[id.lowercased()]?.value.flatMap { $0.machineId == machineId ? $0 : nil }
  }
  func liveModels(machineId: String) -> [ChromiumBrowserModel] {
    models.values.compactMap { $0.value }.filter { $0.machineId == machineId }
  }
  func targets(machineId: String) -> [ChromiumTargetInfo] {
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
  func isAvailable(_ session: String, machineId: String) -> Bool {
    group(session, machineId: machineId) != nil
      || store?.canHostBackgroundBrowser(serverId: machineId, sessionId: session) == true
  }
  func presence(_ session: String, machineId: String) -> [String: Bool] {
    let showing = stores.compactMap(\.value).filter { $0.showsChat(serverId: machineId, sessionId: session) }
    return [
      "available": isAvailable(session, machineId: machineId),
      "showing": !showing.isEmpty,
      "focused": showing.contains { $0.isWindowFocused },
    ]
  }
  func createTarget(session: String, machineId: String, url: String) -> ChromiumBrowserModel? {
    let created =
      group(session, machineId: machineId)?.createBrowserTab?(url)
      ?? store?.createBackgroundBrowserTab(serverId: machineId, sessionId: session, url: url)
    guard let created else { return nil }
    register(created)
    return created
  }
  func activate(_ targetId: String, machineId: String) -> Bool {
    guard let model = model(targetId, machineId: machineId) else { return false }
    model.onSelect?()
    return true
  }
  func close(_ targetId: String, machineId: String) -> Bool {
    guard let model = model(targetId, machineId: machineId) else { return false }
    model.onClose?()
    return true
  }
  func closeUnusedTabs(_ targetIds: [String], machineId: String) {
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

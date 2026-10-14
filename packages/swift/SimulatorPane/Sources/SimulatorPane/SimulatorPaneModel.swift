import CodevisorClient
import CodevisorCloud
import CodevisorCore
import Foundation
import Observation
import ScreenSharing

@MainActor
@Observable
public final class SimulatorPaneModel {
  public enum ListState: Equatable {
    case loading
    case loaded
    case failed(String)
  }

  public private(set) var listState: ListState = .loading
  public private(set) var list: ServerSimulatorList?
  public private(set) var udid: String?
  public private(set) var deviceType: ServerSimulatorDeviceTypeDetail?
  public private(set) var chromes: [String: SimulatorChrome] = [:]
  private(set) var connection: (any SimulatorConnection)?
  public private(set) var settings: ServerSimulatorSettings?
  public private(set) var activity: String?
  public var alert: String?
  public var showsSettings = false
  public var managingSimulators = false
  public private(set) var deleting: Set<String> = []
  public private(set) var chooserFocusRequests = 0
  @ObservationIgnored public var canFocusChooser: () -> Bool = { true }

  public var onPreferencesChanged: ((SimulatorPanePreferences) -> Void)?

  static let hiddenGrace: Duration = .seconds(300)

  @ObservationIgnored let screenFeed = SimulatorScreenFeed()

  @ObservationIgnored let client: any SimulatorClienting
  @ObservationIgnored private let makeConnection: @MainActor (_ udid: String) -> any SimulatorConnection
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var lingering: Task<Void, Never>?
  @ObservationIgnored private var poller: Task<Void, Never>?
  @ObservationIgnored private var loadingType: String?

  public init(
    client: any CodevisorServerClienting, preferences: SimulatorPanePreferences?, workspaceId: UUID, paneId: UUID,
    openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)? = nil
  ) {
    self.client = client
    makeConnection = { udid in
      SimulatorStreamConnection(
        udid: udid, client: client, workspaceId: workspaceId, paneId: paneId, openTunnel: openTunnel)
    }
    clock = ContinuousClock()
    udid = preferences?.udid
  }

  init(
    client: any SimulatorClienting, preferences: SimulatorPanePreferences?, clock: any Clock<Duration>,
    makeConnection: @escaping @MainActor (_ udid: String) -> any SimulatorConnection
  ) {
    self.client = client
    self.clock = clock
    self.makeConnection = makeConnection
    udid = preferences?.udid
  }

  public var device: ServerSimulatorDevice? {
    guard let udid else { return nil }
    return list?.devices.first { $0.udid == udid }
  }

  public var runningDevice: ServerSimulatorDevice? {
    guard let device, device.isBooted, activity == nil else { return nil }
    return device
  }

  public var deviceState: ScreenSharingSimulatorState? { connection?.state }

  public var display: ServerSimulatorDisplay? {
    guard let displays = deviceType?.displays, !displays.isEmpty else { return nil }
    return displays.first { $0.name == deviceState?.display } ?? displays[0]
  }

  public var chrome: SimulatorChrome? {
    (display?.chromeIdentifier ?? deviceType?.chromeIdentifier).flatMap { chromes[$0] }
  }

  public func focusChooser() {
    chooserFocusRequests += 1
  }

  public func appeared() {
    guard !visible else { return }
    visible = true
    lingering?.cancel()
    lingering = nil
    startPolling()
    syncStream()
  }

  public func disappeared() {
    guard visible else { return }
    visible = false
    poller?.cancel()
    poller = nil
    guard connection != nil else { return }
    lingering = Task { [weak self, clock] in
      guard (try? await clock.sleep(for: Self.hiddenGrace)) != nil else { return }
      self?.lingeringExpired()
    }
  }

  public func closed() {
    visible = false
    poller?.cancel()
    poller = nil
    stopStream()
  }

  private func lingeringExpired() {
    guard !visible else { return }
    stopStream()
  }

  public func applyPreferences(_ preferences: SimulatorPanePreferences) {
    guard preferences.udid != udid else { return }
    udid = preferences.udid
    deviceChanged()
  }

  private func startPolling() {
    poller?.cancel()
    poller = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        let busy = self?.device.map { !$0.isBooted && !$0.isShutdown } ?? false
        try? await Task.sleep(for: .seconds(busy ? 1 : 6))
      }
    }
  }

  public func refresh() async {
    do {
      let list = try await client.simulators()
      self.list = list
      listState = .loaded
      if let udid, !list.devices.contains(where: { $0.udid == udid }) { choose(nil) }
      await loadDeviceType()
      syncStream()
    } catch {
      if list == nil { listState = .failed(Self.message(for: error)) }
    }
  }

  public func choose(_ udid: String?) {
    guard udid != self.udid else { return }
    self.udid = udid
    onPreferencesChanged?(SimulatorPanePreferences(udid: udid))
    deviceChanged()
  }

  private func deviceChanged() {
    stopStream()
    deviceType = nil
    settings = nil
    Task {
      await loadDeviceType()
      syncStream()
    }
  }

  private func loadDeviceType() async {
    guard let device, deviceType?.identifier != device.deviceType.identifier,
      loadingType != device.deviceType.identifier
    else { return }
    let identifier = device.deviceType.identifier
    loadingType = identifier
    defer { loadingType = nil }
    guard let detail = try? await client.simulatorDeviceType(identifier: identifier),
      self.device?.deviceType.identifier == identifier
    else { return }
    deviceType = detail
    let wanted = Set(detail.displays.compactMap(\.chromeIdentifier) + [detail.chromeIdentifier].compactMap { $0 })
    for id in wanted where chromes[id] == nil {
      if let chrome = try? await client.simulatorChrome(identifier: id), let parsed = try? SimulatorChrome(chrome) {
        chromes[id] = parsed
      }
    }
  }

  private func syncStream() {
    let running = device?.isBooted == true
    if visible, running, connection == nil, let udid {
      let connection = makeConnection(udid)
      self.connection = connection
      connection.start()
    } else if !running || !(visible || lingering != nil) {
      stopStream()
    }
  }

  private func stopStream() {
    lingering?.cancel()
    lingering = nil
    connection?.stop()
    connection = nil
  }

  public func reconnect() {
    stopStream()
    syncStream()
  }

  public func perform(_ action: ServerSimulatorAction) {
    guard let udid else { return }
    activity =
      switch action {
      case .boot: "Starting…"
      case .shutdown: "Shutting Down…"
      case .restart: "Restarting…"
      case .delete: "Deleting…"
      }
    if action != .boot { stopStream() }
    Task {
      defer { activity = nil }
      do {
        try await client.performSimulatorAction(action, udid: udid)
        if action == .delete { choose(nil) }
      } catch {
        alert = Self.message(for: error)
      }
      await refresh()
    }
  }

  public func rename(to name: String) {
    guard let udid else { return }
    rename(udid, to: name)
  }

  public func rename(_ udid: String, to name: String) {
    Task {
      do { try await client.renameSimulator(udid: udid, name: name) } catch { alert = Self.message(for: error) }
      await refresh()
    }
  }

  public func delete(_ udids: Set<String>) {
    for udid in udids where !deleting.contains(udid) {
      if udid == self.udid { stopStream() }
      deleting.insert(udid)
      Task {
        defer { deleting.remove(udid) }
        do { try await client.performSimulatorAction(.delete, udid: udid) } catch { alert = Self.message(for: error) }
        await refresh()
      }
    }
  }

  public func create(name: String, deviceType: String, runtime: String) {
    Task {
      do {
        _ = try await client.createSimulator(
          name: name, deviceTypeIdentifier: deviceType, runtimeIdentifier: runtime)
        await refresh()
      } catch {
        alert = Self.message(for: error)
      }
    }
  }

  public func loadSettings() async {
    guard let udid, device?.isBooted == true else { return }
    settings = try? await client.simulatorSettings(udid: udid)
  }

  public func change(_ edit: (inout ServerSimulatorSettingsChange) -> Void) {
    guard let udid else { return }
    var change = ServerSimulatorSettingsChange(udid: udid)
    edit(&change)
    settings = settings?.applying(change)
    Task {
      do { settings = try await client.changeSimulatorSettings(change) } catch { alert = Self.message(for: error) }
    }
  }

  public func screenshot() async -> Data? {
    guard let udid else { return nil }
    do {
      return try await client.simulatorScreenshot(udid: udid)
    } catch {
      alert = Self.message(for: error)
      return nil
    }
  }

  @discardableResult
  public func send(_ message: ScreenSharingSimulatorMessage) -> Bool {
    connection?.send(message) ?? false
  }

  private(set) var postureRequests = 0

  public func setPosture(_ posture: String) {
    postureRequests += 1
    send(.posture(posture))
  }

  public func rotate(clockwise: Bool) {
    let current = deviceState?.orientation ?? .portrait
    send(.rotate(current.turned(clockwise: clockwise)))
  }

  static func message(for error: any Error) -> String {
    if case CodevisorServerClientError.httpStatus(let status, let body) = error {
      if let data = body.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let message = object["error"] as? String
      {
        return message
      }
      if status == 501 { return "Simulators need Xcode and the Codevisor app on this Mac." }
    }
    return error.localizedDescription
  }
}

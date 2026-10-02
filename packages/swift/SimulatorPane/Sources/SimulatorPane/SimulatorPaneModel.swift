import CodevisorClient
import CodevisorCloud
import CodevisorCore
import Foundation
import Observation
import ScreenSharing

/// One Simulator pane: the machine's simulators, the device the pane shows, its chrome and
/// settings, and the live stream while the pane is on screen.
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
  /// The device the pane shows (shared with every client through the pane registry).
  public private(set) var udid: String?
  public private(set) var deviceType: ServerSimulatorDeviceTypeDetail?
  /// Chrome bundles by identifier, for the device type's screens.
  public private(set) var chromes: [String: SimulatorChrome] = [:]
  /// The live view while the pane shows a running device: a WebRTC stream, or snapshots where
  /// WebRTC isn't available.
  private(set) var connection: (any SimulatorConnection)?
  public private(set) var settings: ServerSimulatorSettings?
  /// A device action in flight ("Starting…"), shown in place of controls.
  public private(set) var activity: String?
  /// The last failed action, until dismissed.
  public var alert: String?
  /// Whether the device's settings popover is open.
  public var showsSettings = false
  /// Whether the Manage Simulators sheet is up.
  public var managingSimulators = false
  /// Simulators being deleted, shown as such until the list no longer has them.
  public private(set) var deleting: Set<String> = []

  public var onPreferencesChanged: ((SimulatorPanePreferences) -> Void)?

  @ObservationIgnored let client: any CodevisorServerClienting
  /// Makes the live stream for a running device.
  @ObservationIgnored private let makeConnection: @MainActor (_ udid: String) -> any SimulatorConnection
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var poller: Task<Void, Never>?
  @ObservationIgnored private var loadingType: String?

  /// `openTunnel` routes the stream's media through the cloud tunnel to a machine elsewhere.
  public init(
    client: any CodevisorServerClienting, preferences: SimulatorPanePreferences?, workspaceId: UUID, paneId: UUID,
    openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)? = nil
  ) {
    self.client = client
    makeConnection = { udid in
      SimulatorStreamConnection(
        udid: udid, client: client, workspaceId: workspaceId, paneId: paneId, openTunnel: openTunnel)
    }
    udid = preferences?.udid
  }

  /// A model whose device views come from `makeConnection` (tests).
  init(
    client: any CodevisorServerClienting, preferences: SimulatorPanePreferences?,
    makeConnection: @escaping @MainActor (_ udid: String) -> any SimulatorConnection
  ) {
    self.client = client
    self.makeConnection = makeConnection
    udid = preferences?.udid
  }

  public var device: ServerSimulatorDevice? {
    guard let udid else { return nil }
    return list?.devices.first { $0.udid == udid }
  }

  /// The device while it's running and not mid-restart: when its controls do something.
  public var runningDevice: ServerSimulatorDevice? {
    guard let device, device.isBooted, activity == nil else { return nil }
    return device
  }

  /// What the host says the device is doing; nil until the stream reports.
  public var deviceState: ScreenSharingSimulatorState? { connection?.state }

  /// The screen being streamed: the host's choice, else the device type's first.
  public var display: ServerSimulatorDisplay? {
    guard let displays = deviceType?.displays, !displays.isEmpty else { return nil }
    return displays.first { $0.name == deviceState?.display } ?? displays[0]
  }

  public var chrome: SimulatorChrome? {
    (display?.chromeIdentifier ?? deviceType?.chromeIdentifier).flatMap { chromes[$0] }
  }

  // MARK: Lifecycle

  public func appeared() {
    guard !visible else { return }
    visible = true
    startPolling()
    syncStream()
  }

  public func disappeared() {
    guard visible else { return }
    visible = false
    poller?.cancel()
    poller = nil
    syncStream()
  }

  public func closed() {
    visible = false
    poller?.cancel()
    poller = nil
    connection?.stop()
    connection = nil
  }

  /// Another client chose a device for this pane.
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
        // Faster while a device is changing state, so Start feels immediate.
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
      // A deleted device leaves the pane on the picker.
      if let udid, !list.devices.contains(where: { $0.udid == udid }) { choose(nil) }
      await loadDeviceType()
      syncStream()
    } catch {
      if list == nil { listState = .failed(Self.message(for: error)) }
    }
  }

  // MARK: Device

  public func choose(_ udid: String?) {
    guard udid != self.udid else { return }
    self.udid = udid
    onPreferencesChanged?(SimulatorPanePreferences(udid: udid))
    deviceChanged()
  }

  private func deviceChanged() {
    connection?.stop()
    connection = nil
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

  /// Streams while the pane is on screen and its device is running.
  private func syncStream() {
    let wanted = visible && device?.isBooted == true
    if wanted, connection == nil, let udid {
      let connection = makeConnection(udid)
      self.connection = connection
      connection.start()
    } else if !wanted, let connection {
      connection.stop()
      self.connection = nil
    }
  }

  /// Starts the stream again after it failed.
  public func reconnect() {
    connection?.stop()
    connection = nil
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
    if action != .boot {
      connection?.stop()
      connection = nil
    }
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

  /// Renames any of the Mac's simulators.
  public func rename(_ udid: String, to name: String) {
    Task {
      do { try await client.renameSimulator(udid: udid, name: name) } catch { alert = Self.message(for: error) }
      await refresh()
    }
  }

  /// Deletes one of the Mac's simulators (shutting it down first if it runs). Deleting this
  /// pane's device leaves the pane on the gallery.
  public func delete(_ udids: Set<String>) {
    for udid in udids where !deleting.contains(udid) {
      if udid == self.udid {
        connection?.stop()
        connection = nil
      }
      deleting.insert(udid)
      Task {
        defer { deleting.remove(udid) }
        do { try await client.performSimulatorAction(.delete, udid: udid) } catch { alert = Self.message(for: error) }
        await refresh()
      }
    }
  }

  /// Creates a simulator. From the pane it's shown here, started; from Manage Simulators it's
  /// only added to the list.
  public func create(name: String, deviceType: String, runtime: String, show: Bool = true) {
    if show { activity = "Creating…" }
    Task {
      defer { if show { activity = nil } }
      do {
        let created = try await client.createSimulator(
          name: name, deviceTypeIdentifier: deviceType, runtimeIdentifier: runtime)
        await refresh()
        guard show else { return }
        choose(created)
        perform(.boot)
      } catch {
        alert = Self.message(for: error)
      }
    }
  }

  // MARK: Settings

  public func loadSettings() async {
    guard let udid, device?.isBooted == true else { return }
    settings = try? await client.simulatorSettings(udid: udid)
  }

  public func change(_ edit: (inout ServerSimulatorSettingsChange) -> Void) {
    guard let udid else { return }
    var change = ServerSimulatorSettingsChange(udid: udid)
    edit(&change)
    // Optimistic, so controls don't snap back while the device applies it.
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

  // MARK: Input

  @discardableResult
  public func send(_ message: ScreenSharingSimulatorMessage) -> Bool {
    connection?.send(message) ?? false
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

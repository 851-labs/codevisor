import AppKit
import CodevisorClient
import CodevisorCore
import Foundation
import OSLog
import SwiftUI

nonisolated enum ChromiumBrowserHostFrame: Sendable {
  case hello(hostId: String, name: String, idleMs: Int)
  case activity
  case data(channel: String, payload: Data)
  case close(channel: String)

  var encoded: Data {
    let header: [String: Any]
    var body: Data?
    switch self {
    case .hello(let hostId, let name, let idleMs):
      header = ["type": "hello", "hostId": hostId, "name": name, "idleMs": idleMs]
    case .activity: header = ["type": "activity"]
    case .data(let channel, let payload):
      header = ["type": "data", "channel": channel]
      body = payload
    case .close(let channel): header = ["type": "close", "channel": channel]
    }
    var data = (try? JSONSerialization.data(withJSONObject: header)) ?? Data("{}".utf8)
    if let body {
      data.append(0x0A)
      data.append(body)
    }
    return data
  }

  static func decode(_ data: Data) -> (header: [String: Any], body: Data) {
    let split = data.firstIndex(of: 0x0A)
    let headerData = split.map { data[data.startIndex..<$0] } ?? data[...]
    let body = split.map { data[data.index(after: $0)...] } ?? Data()[...]
    let header = (try? JSONSerialization.jsonObject(with: Data(headerData))) as? [String: Any] ?? [:]
    return (header, Data(body))
  }
}

@MainActor
final class ChromiumBrowserHosts {
  struct Identity: Equatable {
    let machineId: String
    let route: MachineController.HTTPConnectionState
    let config: CodevisorServerConfig
  }

  private static let hostIdKey = "BrowserHostId"
  private static let activityInterval: TimeInterval = 10
  private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Codevisor", category: "BrowserHost")
  private var running: [String: (identity: Identity, task: Task<Void, Never>)] = [:]
  private var outboxes: [String: (token: UUID, outbox: AsyncStream<ChromiumBrowserHostFrame>.Continuation)] = [:]
  private var lastActivity = Date()
  private var monitors: [Any] = []

  private var hostId: String {
    if let existing = UserDefaults.standard.string(forKey: Self.hostIdKey) { return existing }
    let created = UUID().uuidString.lowercased()
    UserDefaults.standard.set(created, forKey: Self.hostIdKey)
    return created
  }

  static func identities(_ machines: MachineController) -> [Identity] {
    machines.allMachines.map {
      Identity(
        machineId: $0.id, route: machines.httpConnectionState(forMachineId: $0.id),
        config: machines.serverConfig(for: $0.id))
    }
  }

  func sync(_ environment: AppEnvironment) {
    installActivityMonitors()
    let identities = Self.identities(environment.machines)
    let current = Set(identities.map(\.machineId))
    for (machineId, entry) in running where !current.contains(machineId) {
      entry.task.cancel()
      running[machineId] = nil
    }
    for identity in identities where running[identity.machineId]?.identity != identity {
      running[identity.machineId]?.task.cancel()
      let client = environment.machines.client(for: identity.machineId)
      running[identity.machineId] = (
        identity, Task { [weak self] in await self?.run(identity, client: client) }
      )
    }
  }

  private func run(_ identity: Identity, client: any CodevisorServerClienting) async {
    while !Task.isCancelled {
      let supported = (try? await client.info())?.features?.contains("browser-host-v1") == true
      if supported { await connect(identity) }
      do { try await Task.sleep(for: .seconds(supported ? 3 : 30)) } catch { return }
    }
  }

  private func connect(_ identity: Identity) async {
    let config = identity.config
    guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { return }
    components.scheme = config.baseURL.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/browser-use/host/socket"
    components.query = nil
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    if let token = config.bearerToken, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let transport = config.webSocketTransport ?? URLSessionWebSocketTransport()
    let socket = transport.connect(request, maximumMessageSize: 64 * 1024 * 1024)
    let (frames, outbox) = AsyncStream<ChromiumBrowserHostFrame>.makeStream()
    let machineId = identity.machineId
    let token = UUID()
    outboxes[machineId] = (token, outbox)
    let writer = Task {
      for await frame in frames {
        do { try await socket.send(.data(frame.encoded)) } catch { return }
      }
    }
    let send: @Sendable (ChromiumBrowserHostFrame) -> Void = { outbox.yield($0) }
    var channels: [String: ChromiumAutomationConnection] = [:]
    let idleMs = Int(Date().timeIntervalSince(lastActivity) * 1000)
    outbox.yield(
      .hello(hostId: hostId, name: Host.current().localizedName ?? "Mac", idleMs: max(0, idleMs)))
    await withTaskCancellationHandler {
      do {
        while !Task.isCancelled {
          let data: Data
          switch try await socket.receive() {
          case .data(let bytes): data = bytes
          case .string(let text): data = Data(text.utf8)
          }
          let (header, body) = ChromiumBrowserHostFrame.decode(data)
          guard let channel = header["channel"] as? String else { continue }
          switch header["type"] as? String {
          case "open":
            channels[channel] = ChromiumAutomationBridge.shared.openChannel(
              channel, machineId: machineId, outbox: send)
          case "data": await channels[channel]?.receive(body)
          case "close": await channels.removeValue(forKey: channel)?.close(notifyingHost: false)
          default: continue
          }
        }
      } catch {
        log.info(
          "Browser host connection to \(machineId, privacy: .public) ended: \(error.localizedDescription, privacy: .public)"
        )
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
    }
    socket.cancel(with: .goingAway, reason: nil)
    outbox.finish()
    writer.cancel()
    if outboxes[machineId]?.token == token { outboxes[machineId] = nil }
    for connection in channels.values { await connection.close(notifyingHost: false) }
  }

  private func installActivityMonitors() {
    guard monitors.isEmpty else { return }
    let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) {
      [weak self] event in
      MainActor.assumeIsolated { self?.noteActivity() }
      return event
    }
    if let local { monitors.append(local) }
    monitors.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.noteActivity(force: true) }
      })
  }

  private func noteActivity(force: Bool = false) {
    guard force || Date().timeIntervalSince(lastActivity) >= Self.activityInterval else { return }
    lastActivity = Date()
    for entry in outboxes.values { entry.outbox.yield(.activity) }
  }
}

struct ChromiumBrowserHostSync: ViewModifier {
  @Environment(AppEnvironment.self) private var environment

  func body(content: Content) -> some View {
    content.task(id: ChromiumBrowserHosts.identities(environment.machines)) {
      ChromiumAutomationBridge.shared.hosts.sync(environment)
    }
  }
}

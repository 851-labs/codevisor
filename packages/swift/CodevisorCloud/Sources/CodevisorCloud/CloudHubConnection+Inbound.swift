import Foundation
import CodevisorClient

extension CloudHubConnection {
  private struct TypeProbe: Decodable {
    var t: String
  }

  private struct WelcomeMessage: Decodable {
    var connectionId: String
    var machines: [CloudMachine]
    var resume: String?
    var resumed: Bool?
    var relays: [CloudTunnelConfig.Relay]?
    var tunnel: String?
  }

  private struct PresenceMessage: Decodable {
    var machine: CloudMachine
  }

  private struct ErrorMessage: Decodable {
    var code: String
    var message: String
    var machineId: String?
    var channelId: String?
  }

  func handle(_ message: ServerWebSocketMessage) {
    // Binary messages are relay envelope batches for hub data channels,
    // which this app never opens.
    guard case let .string(text) = message else { return }
    let data = Data(text.utf8)
    guard let probe = try? decoder.decode(TypeProbe.self, from: data) else { return }
    switch probe.t {
    case "welcome":
      guard let welcome = try? decoder.decode(WelcomeMessage.self, from: data) else { return }
      Log.cloud.notice("Cloud hub welcomed this device (\(welcome.machines.count) machines)")
      if welcome.resumed == true && welcome.connectionId == lastConnectionId {
        Log.cloud.notice("Cloud hub resumed this session")
      } else if resumeToken != nil {
        Log.cloud.notice("Cloud hub declined the resume; starting a fresh session")
      }
      resumeToken = welcome.resume
      lastConnectionId = welcome.connectionId
      machines = welcome.machines
      machinesChangedHandler?(machines)
      let tunnelConfig = CloudTunnelConfig(relays: welcome.relays ?? [], enabled: welcome.tunnel == "on")
      lastTunnelConfig = tunnelConfig
      tunnelConfigHandler?(tunnelConfig)
      isWelcomed = true
      let waiters = readyWaiters.values
      readyWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    case "presence":
      guard let presence = try? decoder.decode(PresenceMessage.self, from: data) else { return }
      if let index = machines.firstIndex(where: { $0.deviceId == presence.machine.deviceId }) {
        machines[index] = presence.machine
      } else {
        machines.append(presence.machine)
      }
      machinesChangedHandler?(machines)
    case "error":
      guard let failure = try? decoder.decode(ErrorMessage.self, from: data) else { return }
      Log.cloud.error(
        """
        Cloud hub error \(failure.code, privacy: .public): \(failure.message, privacy: .public) \
        (machine \(failure.machineId ?? "-", privacy: .public), channel \(failure.channelId ?? "-", privacy: .public))
        """
      )
      // Only the grace-expiry broadcast has no channel id and therefore
      // carries machine-wide offline authority; a channel-scoped failure
      // says nothing about the machine's presence.
      if failure.code == "machine-offline", failure.channelId == nil, let machineId = failure.machineId {
        markMachineOffline(machineId)
      }
    case "pong":
      receivePong()
    default:
      // Future message kinds.
      break
    }
  }

  private func markMachineOffline(_ machineId: String) {
    guard let index = machines.firstIndex(where: { $0.deviceId == machineId }) else { return }
    machines[index].online = false
    machinesChangedHandler?(machines)
  }

  /// Applies the REST roster back to the hub's presence view. REST and
  /// WebSocket presence come from the same Durable Object, but either
  /// notification path can be lost during a reconnect; this keeps a stale
  /// local value from leaking into the next presence notification.
  public func reconcileAuthoritativeMachines(_ authoritative: [CloudMachine]) {
    machines = authoritative
  }
}

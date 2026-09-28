import CodevisorClient
import Foundation
import os

/// Reachability: the status probe and what it learns about a machine.
extension MachineController {
  public func refreshStatus(for id: String) async {
    let client = client(for: id)
    let connection = connection(for: id)
    do {
      let info = try await client.info()
      connection.status = MachineStatus(
        isReachable: true,
        label: "\(info.name) \(info.version)",
        cloudDeviceId: info.cloudDeviceId,
        serverId: info.id,
        features: Set(info.features ?? []),
        maxUploadBytes: info.maxUploadBytes
      )
      connection.dataUpgradeProgress = nil
      // A signed-in account with an unregistered local server (it may
      // have started after sign-in): register it now so this machine
      // shows up on the user's other devices.
      if id == CodevisorMachine.local.id, info.cloudDeviceId == nil {
        cloudProvider?.registerLocalMachineIfNeeded()
      }
      // The local machine advertising a cloud device id makes its cloud
      // twin a duplicate identity. The machine list already dedupes; also
      // drop any records synced under the twin id before the probe landed,
      // or they render as doubled projects/chats.
      if id == CodevisorMachine.local.id, let deviceId = info.cloudDeviceId {
        pruneCloudTwinRecords(deviceId: deviceId)
      }
      do {
        connection.updateInfo = try await client.updateInfo(
          refresh: true,
          channel: serverUpdateChannel
        )
      } catch {
        connection.updateInfo = nil
        Log.machines.debug(
          "Update info probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
      }
    } catch {
      // A local server that failed to start has a more useful story
      // than "Unreachable" — surface why instead.
      if id == CodevisorMachine.local.id, case let .unavailable(message) = localServer?.state {
        connection.status = MachineStatus(isReachable: false, label: message)
      } else if await probeDataUpgrade(for: id, client: client) != nil {
        // Booting through a data upgrade: the probe recorded the
        // migration and set the status label.
      } else {
        connection.status = MachineStatus(isReachable: false, label: "Unreachable")
        Log.machines.debug(
          "Status probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  /// Tells "unreachable" from "booting through a data upgrade". A server
  /// binds its port before its blocking migrations run and answers
  /// `/v1/health` with `ok: false` and the migration in flight while every
  /// other route is refused. Records that report on the connection (cleared
  /// once the server answers ready) with a matching status label, and
  /// returns the health while the upgrade runs; nil otherwise.
  @discardableResult
  func probeDataUpgrade(
    for machineId: String,
    client: any CodevisorServerClienting
  ) async -> ServerHealth? {
    let connection = connection(for: machineId)
    guard let health = try? await client.health(), health.database != "ready" else {
      connection.dataUpgradeProgress = nil
      return nil
    }
    let failed = health.database == "failed"
    let genericFailure = "The server couldn't finish updating its data."
    var migration =
      health.migration
      ?? ServerMigrationProgress(id: "data-upgrade", name: "Updating server data", completed: 0, total: 0)
    if failed, migration.error == nil { migration.error = genericFailure }
    connection.dataUpgradeProgress = migration
    connection.status = MachineStatus(
      isReachable: false,
      label: failed ? "Server data update failed" : "Updating server data…"
    )
    return health
  }
}

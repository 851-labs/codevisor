import CodevisorClient
import Foundation
import os

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
      if id == CodevisorMachine.local.id, info.cloudDeviceId == nil {
        cloudProvider?.registerLocalMachineIfNeeded()
      }
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
      if id == CodevisorMachine.local.id, case let .unavailable(message) = localServer?.state {
        connection.status = MachineStatus(isReachable: false, label: message)
      } else if await probeDataUpgrade(for: id, client: client) != nil {
      } else {
        connection.status = MachineStatus(isReachable: false, label: "Unreachable")
        Log.machines.debug(
          "Status probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

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

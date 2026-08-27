import CodevisorClient
import Foundation
import os

/// Reachability: the direct probe, the Phase 22 relay fallback for
/// configured machines whose direct route is down, and the persisted
/// direct↔cloud link both of those maintain.
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
                route: routeInUse(forMachineId: id),
                serverId: info.id
            )
            // Persist the direct↔cloud link on the record itself: dedup and
            // the relay fallback must both survive relaunches whose direct
            // probe never succeeds.
            if !id.hasPrefix(CodevisorMachine.cloudIdPrefix),
                let deviceId = info.cloudDeviceId,
                let index = registry.remoteMachines.firstIndex(where: { $0.id == id }),
                registry.remoteMachines[index].cloudDeviceId != deviceId
            {
                registry.remoteMachines[index].cloudDeviceId = deviceId
                persist()
            }
            // A signed-in account with an unregistered local server (it may
            // have started after sign-in): register it now so this machine
            // shows up on the user's other devices.
            if id == CodevisorMachine.local.id, info.cloudDeviceId == nil {
                cloudProvider?.registerLocalMachineIfNeeded()
            }
            // A CONFIGURED machine advertising a cloud device id makes its
            // cloud twin a duplicate identity. The machine list already
            // dedupes; also drop any records synced under the twin id before
            // the probe landed, or they render as doubled projects/chats.
            if !id.hasPrefix(CodevisorMachine.cloudIdPrefix),
                let deviceId = info.cloudDeviceId
            {
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
            } else if case CodevisorServerClientError.httpStatus(401, _) = error {
                // The server answered — the token is just wrong (or the
                // machine was paired against a different server on that host).
                // Say so, so the user fixes the token instead of chasing a
                // phantom network problem.
                connection.status = MachineStatus(isReachable: false, label: "Invalid connection token")
            } else if let relayed = await probeRelayFallback(forMachineId: id) {
                // The direct route is down but the machine answers through
                // its cloud relay — reachable, just not directly.
                connection.status = relayed
            } else {
                connection.status = MachineStatus(isReachable: false, label: "Unreachable")
                Log.machines.debug(
                    "Status probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    #if DEBUG
        /// Seeds a persisted direct↔cloud link without a live probe — tests
        /// model "the link was learned on an earlier launch". Lives in this
        /// file because `registry`'s setter is file-private.
        func adoptCloudLinkForTesting(machineId: String, deviceId: String) {
            guard let index = registry.remoteMachines.firstIndex(where: { $0.id == machineId })
            else { return }
            registry.remoteMachines[index].cloudDeviceId = deviceId
        }
    #endif

    /// Probes a configured machine through its persisted cloud twin's relay.
    /// Nil when no link exists, the account is signed out, or the relay
    /// probe fails too.
    private func probeRelayFallback(forMachineId id: String) async -> MachineStatus? {
        guard let config = relayFallbackConfig(forConfiguredMachineId: id) else { return nil }
        let relayClient = CodevisorServerClient(
            config: config,
            requestGate: requestGate,
            machineId: id
        )
        guard let info = try? await relayClient.info() else { return nil }
        return MachineStatus(
            isReachable: true,
            label: "\(info.name) \(info.version) — via Codevisor Cloud",
            cloudDeviceId: info.cloudDeviceId,
            route: .relay,
            serverId: info.id
        )
    }
}

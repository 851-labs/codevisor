import CodevisorClient
import Foundation

/// Client and transport routing: how a machine id becomes something the
/// app can actually talk to — relay-backed for cloud ids, plain HTTP for
/// configured machines, and a loudly-failing client when a cloud id
/// can't be routed yet.
extension MachineController {
    func clientIfKnown(for machineId: String) -> (any CodevisorServerClienting)? {
        guard machine(for: machineId) != nil else { return nil }
        return client(for: machineId)
    }

    public func client(for machineId: String) -> any CodevisorServerClienting {
        // Cloud machines get a real HTTP client whose transports tunnel every
        // request/WebSocket through the account's encrypted relay, so all
        // existing features work unchanged.
        if let config = relayServerConfig(forMachineId: machineId) {
            return CodevisorServerClient(
                config: config,
                requestGate: requestGate,
                machineId: machineId
            )
        }
        // A cloud machine id with no relay yet (launch-time roster still
        // loading, signed out, relay down) must FAIL its requests, never
        // silently answer as the local machine: a draft restored onto a
        // cloud project at launch once fetched the local server's harness
        // catalog through this fallback and persisted it under the cloud
        // machine's cache key — poisoning every later composer open.
        if CodevisorMachine.cloudDeviceId(forMachineId: machineId) != nil {
            return CodevisorServerClient(config: .unreachable(machineId: machineId))
        }
        // A configured machine whose direct route is down but whose persisted
        // cloud twin answers rides the relay (Phase 22) — same machine, same
        // records, different transport.
        if statusByMachineId[machineId]?.route == .relay,
            let config = relayFallbackConfig(forConfiguredMachineId: machineId)
        {
            return CodevisorServerClient(
                config: config,
                requestGate: requestGate,
                machineId: machineId
            )
        }
        let machine = machine(for: machineId) ?? CodevisorMachine.local
        return clientFactory(machine)
    }

    /// The relay config backing a CONFIGURED machine's fallback route, via
    /// the cloud device id persisted on its record. Nil without a link or a
    /// signed-in cloud account.
    func relayFallbackConfig(forConfiguredMachineId machineId: String) -> CodevisorServerConfig? {
        guard let deviceId = registry.remoteMachines.first(where: { $0.id == machineId })?.cloudDeviceId,
            let cloudProvider, cloudProvider.isCloudSignedIn,
            let cloud = cloudProvider.cloudMachines.first(where: { $0.deviceId == deviceId })
        else { return nil }
        return cloudProvider.relayServerConfig(for: cloud)
    }

    /// The route a machine's traffic is currently using.
    func routeInUse(forMachineId machineId: String) -> MachineRoute {
        statusByMachineId[machineId]?.route == .relay ? .relay : .direct
    }

    /// The server config for a machine id — relay-backed for cloud machines,
    /// plain otherwise. Consumers that build their own transports from a
    /// config (terminals) use this so cloud machines tunnel automatically.
    public func serverConfig(for machineId: String) -> CodevisorServerConfig {
        if let config = relayServerConfig(forMachineId: machineId) {
            return config
        }
        return (machine(for: machineId) ?? selectedMachine).serverConfig
    }

    private func relayServerConfig(forMachineId machineId: String) -> CodevisorServerConfig? {
        guard let cloud = cloudMachine(forMachineId: machineId) else { return nil }
        return cloudProvider?.relayServerConfig(for: cloud)
    }

    /// The machine's effective HTTP origin for consumers that must dial a
    /// real socket instead of the in-process relay transports (plugin pane
    /// webviews, external helper processes): direct machines answer their
    /// configured baseURL; cloud machines lazily start the in-app loopback
    /// bridge and answer its `http://127.0.0.1:<port>` address, waiting
    /// (bounded) for the listener to come up. Nil when the machine is gone or
    /// the relay bridge can't start (signed out, relay down).
    public func effectiveHTTPBaseURL(
        forMachineId machineId: String,
        timeout: Duration = .seconds(10)
    ) async -> URL? {
        guard let cloud = cloudMachine(forMachineId: machineId) else {
            return machine(for: machineId)?.baseURL
        }
        guard let cloudProvider else { return nil }
        // The first call kicks the bridge off; poll for the published port —
        // it appears via an observable the synchronous accessor can't await.
        let deadline = ContinuousClock.now + timeout
        while true {
            if let url = cloudProvider.loopbackBaseURL(for: cloud) { return url }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

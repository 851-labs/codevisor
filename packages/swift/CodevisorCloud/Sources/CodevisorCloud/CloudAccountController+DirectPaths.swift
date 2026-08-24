import Foundation

// MARK: - Direct LAN paths

extension CloudAccountController {
    /// Re-probes direct paths after each machine refresh. Only online
    /// machines whose presented key matches the TOFU pin are candidates — a
    /// changed-key machine gets no pipe of any kind until the user re-trusts
    /// it, and the pin (not anything the LAN listener claims) is what every
    /// direct channel seals toward.
    func reconcileDirectPaths() {
        guard state.isSignedIn, let hub = hubConnection() else {
            directPaths.dropAll()
            return
        }
        let verified = machines.filter { $0.online && verifiedMachineKey(for: $0) != nil }
        directPaths.reconcile(machines: verified) { machine in
            CloudRelayEndpoint(
                hub: hub,
                machineDeviceId: machine.deviceId,
                machinePublicKey: machine.publicKey
            )
        }
    }

    /// One transport per machine that picks the best live pipe at
    /// channel-open time: the verified direct pipe when one is up, else the
    /// relay. Channels are ephemeral, so a pipe change simply routes the next
    /// open — nothing migrates.
    func machineTransport(
        for machine: CloudMachine,
        verifiedKey: String,
        hub: CloudHubConnection
    ) -> any CloudChannelTransport {
        let relay = CloudRelayEndpoint(
            hub: hub,
            machineDeviceId: machine.deviceId,
            machinePublicKey: verifiedKey
        )
        let directPaths = directPaths
        let deviceId = machine.deviceId
        return SwitchingChannelTransport(machineDeviceId: deviceId) {
            await directPaths.transport(for: deviceId, publicKey: verifiedKey) ?? relay
        }
    }
}

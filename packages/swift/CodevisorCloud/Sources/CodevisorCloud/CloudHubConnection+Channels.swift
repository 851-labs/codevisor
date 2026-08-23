import Foundation
import ACPKit
import CodevisorClient

extension CloudHubConnection {
    /// Opens an end-to-end encrypted channel to a machine. `onMessage` gets
    /// each decrypted inbound payload; `onClosed` fires once when the channel
    /// ends (with the peer's close reason, or nil on connection loss). Both
    /// may be invoked before this returns.
    public func openChannel(
        machineDeviceId: String,
        machinePublicKey: String,
        channelType: String,
        params: JSONValue?,
        onMessage: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        try await openChannel(
            machineDeviceId: machineDeviceId,
            machinePublicKey: machinePublicKey,
            channelType: channelType,
            params: params,
            flowControlled: false,
            onMessage: { data, _ in onMessage(data) },
            onCredit: { _ in },
            onClosed: onClosed
        )
    }

    /// Opens a raw channel whose owner explicitly grants receive credit and
    /// observes peer grants before sending. Credit is counted in encoded
    /// ciphertext bytes, matching the relay wire format.
    public func openFlowControlledChannel(
        machineDeviceId: String,
        machinePublicKey: String,
        channelType: String,
        params: JSONValue?,
        onMessage: @escaping @Sendable (Data, Int) -> Void,
        onCredit: @escaping @Sendable (Int) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        try await openChannel(
            machineDeviceId: machineDeviceId,
            machinePublicKey: machinePublicKey,
            channelType: channelType,
            params: params,
            flowControlled: true,
            onMessage: onMessage,
            onCredit: onCredit,
            onClosed: onClosed
        )
    }

    private func openChannel(
        machineDeviceId: String,
        machinePublicKey: String,
        channelType: String,
        params: JSONValue?,
        flowControlled: Bool,
        onMessage: @escaping @Sendable (Data, Int) -> Void,
        onCredit: @escaping @Sendable (Int) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            let diagnosticMachine = machines.first(where: { $0.deviceId == machineDeviceId })
            Log.cloud.notice(
                "CLOUDRELAYDBG channel.open.begin type=\(channelType, privacy: .public) welcomed=\(self.isWelcomed) machineKnown=\(diagnosticMachine != nil) machineOnline=\(diagnosticMachine?.online ?? false)"
            )
        #endif
        try await waitUntilReady()
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            Log.cloud.notice(
                "CLOUDRELAYDBG channel.open.ready type=\(channelType, privacy: .public)"
            )
        #endif
        try await waitUntilMachineOnline(machineDeviceId)
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            Log.cloud.notice(
                "CLOUDRELAYDBG channel.open.machineReady type=\(channelType, privacy: .public)"
            )
        #endif
        let identity = try appDeviceIdentity()
        let opened = try CloudChannelCrypto.openChannel(
            openerSecretKey: identity.secretKey,
            responderPublicKey: machinePublicKey
        )
        let channelId = UUID().uuidString.lowercased()
        var payload: [String: JSONValue] = ["channelType": .string(channelType)]
        if let params {
            payload["params"] = params
        }
        let plaintext = try encoder.encode(JSONValue.object(payload))
        let sealed = try opened.cipher.seal(
            plaintext,
            channelId: channelId,
            direction: .openerToResponder,
            seq: 0
        )
        let state = ChannelState(
            machineDeviceId: machineDeviceId,
            cipher: opened.cipher,
            nextOutboundSeq: 1,
            flowControlled: flowControlled,
            onMessage: onMessage,
            onCredit: onCredit,
            onClosed: onClosed
        )
        channels[channelId] = state
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            Log.cloud.notice(
                "CLOUDRELAYDBG channel.open type=\(channelType, privacy: .public) id=\(String(channelId.prefix(8)), privacy: .public) active=\(self.channels.count)"
            )
        #endif
        do {
            try sendRelay(
                machineId: machineDeviceId,
                frame: .open(
                    channelId: channelId,
                    seq: 0,
                    ephemeralKey: opened.ephemeralPublicKey,
                    sealed: CloudSealedPayload(box: sealed)
                ))
        } catch {
            channels.removeValue(forKey: channelId)
            throw error
        }
        return CloudRelayChannel(id: channelId, hub: self)
    }

    func send(channelId: String, plaintext: Data) throws -> Int {
        guard let state = channels[channelId] else {
            throw CloudHubConnectionError.channelClosed
        }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            Log.cloud.notice(
                "CLOUDRELAYDBG channel.send id=\(String(channelId.prefix(8)), privacy: .public) seq=\(seq) bytes=\(plaintext.count)"
            )
        #endif
        let sealed = try state.cipher.seal(
            plaintext,
            channelId: channelId,
            direction: .openerToResponder,
            seq: seq
        )
        try sendRelay(
            machineId: state.machineDeviceId,
            frame: .data(
                channelId: channelId,
                seq: seq,
                sealed: CloudSealedPayload(box: sealed)
            ))
        return sealed.utf8.count
    }

    func grantCredit(channelId: String, bytes: Int) throws {
        guard let state = channels[channelId] else {
            throw CloudHubConnectionError.channelClosed
        }
        guard bytes > 0, state.inboundCredit <= Int.max - bytes else {
            abortChannel(channelId, reason: .protocolError)
            throw CloudHubConnectionError.channelClosed
        }
        if state.flowControlled {
            state.inboundCredit += bytes
        }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        try sendRelay(
            machineId: state.machineDeviceId,
            frame: .credit(channelId: channelId, seq: seq, bytes: bytes)
        )
    }

    /// Closes a channel from this side. `onClosed` is not invoked for
    /// self-initiated closes.
    func closeChannel(_ channelId: String, reason: CloudChannelCloseReason) {
        guard let state = channels.removeValue(forKey: channelId) else { return }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            Log.cloud.notice(
                "CLOUDRELAYDBG channel.close id=\(String(channelId.prefix(8)), privacy: .public) seq=\(seq) reason=\(reason.rawValue, privacy: .public) active=\(self.channels.count)"
            )
        #endif
        try? sendRelay(
            machineId: state.machineDeviceId,
            frame: .close(
                channelId: channelId,
                seq: seq,
                reason: reason
            ))
    }

    /// Aborts a misbehaving channel: notifies the peer and the local owner.
    func abortChannel(_ channelId: String, reason: CloudChannelCloseReason) {
        guard let state = channels.removeValue(forKey: channelId) else { return }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        try? sendRelay(
            machineId: state.machineDeviceId,
            frame: .close(
                channelId: channelId,
                seq: seq,
                reason: reason
            ))
        state.onClosed(reason)
    }
}

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
    }

    private struct PresenceMessage: Decodable {
        var machine: CloudMachine
    }

    private struct InboundRelayHeader: Decodable {
        var machineId: String
        var frame: CloudRelayFrame
    }

    private struct MachineResetMessage: Decodable {
        var machineId: String
    }

    private struct ErrorMessage: Decodable {
        var code: String
        var message: String
        var machineId: String?
        var channelId: String?
    }

    func handle(_ message: ServerWebSocketMessage) async {
        let data: Data
        switch message {
        case let .data(payload):
            // Binary messages are relay envelope batches; malformed ones are
            // dropped (the hub never sends them).
            guard let envelopes = try? CloudRelayWire.decode(payload) else { return }
            for envelope in envelopes {
                guard let relay = try? decoder.decode(InboundRelayHeader.self, from: envelope.header)
                else { continue }
                handleRelay(relay.frame, payload: envelope.payload)
            }
            return
        case let .string(text):
            data = Data(text.utf8)
        }
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else { return }
        switch probe.t {
        case "welcome":
            guard let welcome = try? decoder.decode(WelcomeMessage.self, from: data) else { return }
            Log.cloud.info("Cloud hub welcomed this device (\(welcome.machines.count) machines)")
            suspensionTask?.cancel()
            suspensionTask = nil
            let resumed = welcome.resumed == true && welcome.connectionId == lastConnectionId
            resumeToken = welcome.resume
            lastConnectionId = welcome.connectionId
            if !resumed {
                // Fresh identity: peer ids changed, so held channels are dead.
                failAllChannels()
            }
            machines = welcome.machines
            for machine in welcome.machines where machine.online {
                resumeMachineWaiters(for: machine.deviceId)
            }
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
            if presence.machine.online {
                resumeMachineWaiters(for: presence.machine.deviceId)
            } else {
                // The machine's hub socket is gone, and its channel state is
                // in-memory only — existing channels cannot survive its
                // reconnect. Close them now so relayed streams fail fast and
                // resume from their cursors instead of hanging forever on a
                // channel the machine no longer knows about.
                closeChannels(for: presence.machine.deviceId)
            }
        case "machine-reset":
            guard let reset = try? decoder.decode(MachineResetMessage.self, from: data) else { return }
            // The machine completed a fresh hello: its in-memory channel
            // state is gone, so every channel toward it is dead even though
            // the machine is online. Close them; consumers re-open on the
            // machine's fresh socket (the online presence follows this frame).
            closeChannels(for: reset.machineId)
        case "error":
            guard let failure = try? decoder.decode(ErrorMessage.self, from: data) else { return }
            Log.cloud.error(
                """
                Cloud hub error \(failure.code, privacy: .public): \(failure.message, privacy: .public) \
                (machine \(failure.machineId ?? "-", privacy: .public), channel \(failure.channelId ?? "-", privacy: .public))
                """
            )
            if failure.code == "machine-offline", let machineId = failure.machineId {
                markMachineOffline(machineId)
                closeChannels(for: machineId)
            } else if let channelId = failure.channelId {
                channels.removeValue(forKey: channelId)?.onClosed(nil)
            } else if let machineId = failure.machineId {
                closeChannels(for: machineId)
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
    }

    private func closeChannels(for machineId: String) {
        let affected = channels.filter { $0.value.machineDeviceId == machineId }
        for (id, state) in affected {
            channels.removeValue(forKey: id)
            state.onClosed(nil)
        }
    }

    private func handleRelay(_ frame: CloudRelayFrame, payload: Data) {
        guard let state = channels[frame.channelId] else {
            #if DEBUG || NAVIGATION_DIAGNOSTICS
                Log.cloud.notice(
                    "CLOUDRELAYDBG channel.inbound.unknown id=\(String(frame.channelId.prefix(8)), privacy: .public) seq=\(frame.seq)"
                )
            #endif
            return
        }
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            let kind =
                switch frame {
                case .open: "open"
                case .data: "data"
                case .credit: "credit"
                case .close: "close"
                }
            Log.cloud.notice(
                "CLOUDRELAYDBG channel.inbound kind=\(kind, privacy: .public) id=\(String(frame.channelId.prefix(8)), privacy: .public) seq=\(frame.seq) expected=\(state.nextInboundSeq)"
            )
        #endif
        // Per-direction seqs are strictly monotonic from 0; a gap or repeat
        // is a protocol error and kills the channel.
        guard frame.seq == state.nextInboundSeq else {
            abortChannel(frame.channelId, reason: .protocolError)
            return
        }
        state.nextInboundSeq += 1
        switch frame {
        case .open:
            // Machines never open channels toward the app.
            abortChannel(frame.channelId, reason: .protocolError)
        case let .data(channelId, seq):
            do {
                var plaintext = try state.cipher.open(
                    payload,
                    channelId: channelId,
                    direction: .responderToOpener,
                    seq: seq
                )
                if state.compressed {
                    plaintext = try Self.unframe(plaintext)
                }
                let sealedBytes = payload.count
                if state.flowControlled {
                    guard sealedBytes <= state.inboundCredit else {
                        abortChannel(channelId, reason: .protocolError)
                        return
                    }
                    state.inboundCredit -= sealedBytes
                }
                state.onMessage(plaintext, sealedBytes)
                if !state.flowControlled {
                    // Legacy structured channels consume each message
                    // immediately, so replenish their peer automatically.
                    try? grantCredit(channelId: channelId, bytes: sealedBytes)
                }
            } catch {
                abortChannel(channelId, reason: .cryptoError)
            }
        case let .credit(channelId, _, bytes):
            guard bytes > 0 else {
                abortChannel(channelId, reason: .protocolError)
                return
            }
            state.onCredit(bytes)
        case let .close(channelId, _, reason):
            channels.removeValue(forKey: channelId)
            state.onClosed(reason)
        }
    }

    /// Strips the negotiated framing byte, inflating DEFLATE bodies. Bad
    /// framing surfaces as crypto-error, same as any undecodable payload.
    private static func unframe(_ plaintext: Data) throws -> Data {
        guard let framing = plaintext.first else { throw CloudDeflateError.corruptInput }
        let body = plaintext.dropFirst()
        switch framing {
        case CloudDeflate.framingRaw: return Data(body)
        case CloudDeflate.framingDeflate: return try CloudDeflate.inflate(Data(body))
        default: throw CloudDeflateError.corruptInput
        }
    }
}

import type { CloudMachinePresence, RelayFrameHeader } from "@codevisor/api"

import { ChannelOpener, type OutgoingChannel } from "./channel-opener.js"
import type { PeerKeyPinStore } from "./peer-pins.js"

/// The machine-plane peer state a CloudMachineConnection keeps for its
/// account: the machine list (welcome + presence, from hubs that support
/// MACHINE_PEERS_FEATURE) and the channels this machine opens toward the
/// others. Presence transitions end the channels they doom.

/// Why a machine→machine channel could not be opened (nothing was sent).
export type ChannelOpenFailure =
  /// No hub connection (or resumable session) to send through.
  | "not-connected"
  /// The hub predates machine→machine channels (no machine list).
  | "peers-unsupported"
  | "unknown-machine"
  | "machine-offline"
  /// The target runs a version that takes no channels from other machines.
  | "machine-outdated"

export class ChannelOpenError extends Error {
  override readonly name = "ChannelOpenError"
  constructor(
    readonly reason: ChannelOpenFailure,
    message: string
  ) {
    super(message)
  }
}

export interface MachinePeersOptions {
  selfDeviceId: string
  secretKey: string
  peerKeyPins?: PeerKeyPinStore
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  onMachinesChanged?: (machines: ReadonlyArray<CloudMachinePresence>) => void
  sendEnvelope: (machineId: string, frame: RelayFrameHeader, payload?: Uint8Array) => void
}

export class MachinePeers {
  /// By device id; undefined until a peer-aware hub welcomed us.
  #machines: Map<string, CloudMachinePresence> | undefined
  readonly #opener: ChannelOpener

  constructor(private readonly options: MachinePeersOptions) {
    this.#opener = new ChannelOpener({
      secretKey: options.secretKey,
      ...(options.peerKeyPins === undefined ? {} : { peerKeyPins: options.peerKeyPins }),
      ...(options.onPeerKeyMismatch === undefined
        ? {}
        : { onPeerKeyMismatch: options.onPeerKeyMismatch }),
      sendEnvelope: options.sendEnvelope
    })
  }

  /// The account's machines (this one included) as the hub last reported
  /// them (kept through reconnects); undefined before the first welcome,
  /// after clear(), or when the hub predates machine peers.
  list(): ReadonlyArray<CloudMachinePresence> | undefined {
    return this.#machines === undefined ? undefined : [...this.#machines.values()]
  }

  open(
    deviceId: string,
    channelType: string,
    params: unknown,
    connected: boolean
  ): OutgoingChannel {
    if (!connected) throw new ChannelOpenError("not-connected", "not connected to the cloud relay")
    if (this.#machines === undefined) {
      throw new ChannelOpenError(
        "peers-unsupported",
        "the cloud relay does not support machine-to-machine channels yet"
      )
    }
    const target = this.#machines.get(deviceId)
    if (target === undefined || deviceId === this.options.selfDeviceId) {
      throw new ChannelOpenError("unknown-machine", "no such machine on this account")
    }
    if (!target.online) throw new ChannelOpenError("machine-offline", "the machine is offline")
    if (target.machinePeers !== true) {
      throw new ChannelOpenError(
        "machine-outdated",
        "the machine runs a Codevisor version without machine-to-machine channels"
      )
    }
    return this.#opener.open(target, channelType, params)
  }

  welcome(machines: ReadonlyArray<CloudMachinePresence> | undefined): void {
    this.#set(
      machines === undefined
        ? undefined
        : new Map(machines.map((machine) => [machine.deviceId, machine]))
    )
  }

  presence(machine: CloudMachinePresence): void {
    const machines = new Map(this.#machines)
    machines.set(machine.deviceId, machine)
    this.#set(machines)
    if (!machine.online) this.#opener.dropMachine(machine.deviceId)
  }

  /// The machine restarted: its channel state is gone.
  reset(machineId: string): void {
    this.#opener.dropMachine(machineId)
  }

  hubError(machineId: string, channelId: string | undefined): void {
    this.#opener.handleHubError(machineId, channelId)
  }

  handleRelay(machineId: string, frame: RelayFrameHeader, payload: Uint8Array): void {
    this.#opener.handleRelay(machineId, frame, payload)
  }

  /// This machine's own pipe died for good.
  dropChannels(): void {
    this.#opener.dropAll()
  }

  clear(): void {
    this.#machines = undefined
  }

  #set(machines: Map<string, CloudMachinePresence> | undefined): void {
    this.#machines = machines
    if (machines !== undefined) this.options.onMachinesChanged?.([...machines.values()])
  }
}

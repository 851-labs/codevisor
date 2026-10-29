import { readFile, rm, writeFile } from "node:fs/promises"
import { hostname } from "node:os"
import { dirname, join } from "node:path"
import { deflateRawSync, inflateRawSync } from "node:zlib"

import { GATEWAY_CHANNEL_TYPE, type CloudMachinePresence } from "@codevisor/api"
import {
  BYTE_STREAM_CHANNEL_TYPE,
  CloudMachineConnection,
  DirectChannelHost,
  GatewayChannelError,
  HTTP_CHANNEL_TYPE,
  makePeerKeyPinStore,
  parsePeerKeyPins,
  createMachineInvite,
  provisionMachine,
  redeemMachineInvite,
  removeMachinePeer,
  requestOverGatewayChannel,
  serializePeerKeyPins,
  WS_CHANNEL_TYPE,
  type ChannelPeer,
  type CloudSocket,
  type FetchLike,
  type GatewayExchange,
  type MachineConnectionState,
  type MachineCredentials,
  type PeerKeyPinStore
} from "@codevisor/cloud-client"

import type { CloudServerControl } from "../server-context-types.js"
import { field, stringField } from "../unknown-values.js"
import { removeMachineFromCloudAccount } from "./cloud-account-removal.js"
import { socketFactory } from "./cloud-bridge-socket.js"
import { byteStreamChannelHandler } from "./cloud-byte-stream.js"
import { inboxFrameHandler, machineApiRequest, type CloudInbox } from "./cloud-inbox.js"
import {
  gatewayLoopbackHandler,
  httpChannelHandler,
  wsChannelHandler
} from "./cloud-proxy-handlers.js"
import { prepareMachineTunnel, tunnelKeyPath, tunnelPinsPath } from "./cloud-tunnel.js"
import type { TicketBook } from "./fleet-tickets.js"

export interface CloudBridgeOptions {
  readonly credentialsPath: string
  readonly machineName: string
  readonly icon: Promise<string>
  readonly appVersion: string
  readonly serverId?: string
  readonly localBaseUrl: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly log: (line: string) => void
  readonly releaseChannel?: () => "stable" | "alpha" | undefined
  readonly fetchImpl?: FetchLike
  readonly fleetCallers?: TicketBook<ChannelPeer>
  readonly inbox?: CloudInbox
}

export type CloudBridgeManagedBy = "app" | "external"

export interface CloudBridge {
  readonly stop: () => void
  readonly state: () => MachineConnectionState
  readonly deviceId: string
  readonly serverUrl: string
  readonly managedBy: CloudBridgeManagedBy
  readonly machineName: string
  readonly acceptDirect: (socket: CloudSocket) => void
  readonly machines: () => ReadonlyArray<CloudMachinePresence> | undefined
  readonly requestGateway: (
    deviceId: string,
    body: string,
    signal?: AbortSignal
  ) => Promise<GatewayExchange>
  readonly bridgeTunnelMedia: NonNullable<CloudServerControl["bridgeTunnelMedia"]>
  readonly setDirectPaths: NonNullable<CloudServerControl["setDirectPaths"]>
}

interface StoredCloudCredentials {
  credentials: MachineCredentials
  managedBy: CloudBridgeManagedBy
  machineName?: string
}

const readCredentials = async (path: string): Promise<StoredCloudCredentials | undefined> => {
  try {
    const parsed: unknown = JSON.parse(await readFile(path, "utf8"))
    const serverUrl = stringField(parsed, "serverUrl")
    const deviceId = stringField(parsed, "deviceId")
    const publicKey = stringField(parsed, "publicKey")
    const secretKey = stringField(parsed, "secretKey")
    const apiKey = stringField(parsed, "apiKey")
    const machineName = stringField(parsed, "machineName")
    if (
      serverUrl !== undefined &&
      deviceId !== undefined &&
      publicKey !== undefined &&
      secretKey !== undefined &&
      apiKey !== undefined
    ) {
      return {
        credentials: { serverUrl, deviceId, publicKey, secretKey, apiKey },
        managedBy: field(parsed, "managedBy") === "app" ? "app" : "external",
        ...(machineName === undefined ? {} : { machineName })
      }
    }
    return undefined
  } catch {
    return undefined
  }
}

const devProvision = async (
  options: CloudBridgeOptions
): Promise<MachineCredentials | undefined> => {
  const url = options.env.CODEVISOR_DEV_CLOUD_URL
  const token = options.env.CODEVISOR_DEV_CLOUD_TOKEN
  if (url === undefined || token === undefined || token === "") return undefined
  try {
    const credentials = await provisionMachine(
      (input, init) => fetch(input, init),
      url.replace(/\/+$/, ""),
      token,
      options.machineName
    )
    await writeFile(options.credentialsPath, JSON.stringify(credentials, null, 2), { mode: 0o600 })
    return credentials
  } catch (cause) {
    options.log(
      `Cloud dev auto-provision failed: ${cause instanceof Error ? cause.message : String(cause)}`
    )
    return undefined
  }
}

const RELAY_COALESCE_MS = 5

const COMPRESS_MIN_BYTES = 512

const compressPayload = (bytes: Uint8Array): Uint8Array | undefined => {
  if (bytes.byteLength < COMPRESS_MIN_BYTES) return undefined
  const deflated = deflateRawSync(bytes)
  return deflated.byteLength < bytes.byteLength ? new Uint8Array(deflated) : undefined
}

const decompressPayload = (bytes: Uint8Array): Uint8Array => new Uint8Array(inflateRawSync(bytes))

const validateOrReprovision = async (
  options: CloudBridgeOptions,
  credentials: MachineCredentials
): Promise<MachineCredentials> => {
  if (options.env.CODEVISOR_DEV_CLOUD_URL === undefined) return credentials
  try {
    const probe = await fetch(`${credentials.serverUrl}/api/machine/credential`, {
      headers: { "x-api-key": credentials.apiKey }
    })
    if (probe.status !== 401) return credentials
  } catch {
    return credentials
  }
  options.log("Cloud: stored dev credentials are stale (cloud reset?); re-provisioning.")
  return (await devProvision(options)) ?? credentials
}

const peerPinsPath = (credentialsPath: string): string =>
  join(dirname(credentialsPath), "cloud-peers.json")

const loadPeerKeyPins = async (options: CloudBridgeOptions): Promise<PeerKeyPinStore> => {
  const path = peerPinsPath(options.credentialsPath)
  const initial = parsePeerKeyPins(await readFile(path, "utf8").catch(() => ""))
  return makePeerKeyPinStore({
    initial,
    persist: (peers) => {
      writeFile(path, serializePeerKeyPins(peers), { mode: 0o600 }).catch((cause: unknown) => {
        options.log(
          `Cloud: failed to persist app key pins: ${cause instanceof Error ? cause.message : String(cause)}`
        )
      })
    }
  })
}

const makeBridge = async (
  options: CloudBridgeOptions,
  credentials: MachineCredentials,
  managedBy: CloudBridgeManagedBy,
  peerKeyPins: PeerKeyPinStore
): Promise<CloudBridge> => {
  const machineName = options.machineName === "" ? hostname() : options.machineName
  const channelHandlers = {
    [BYTE_STREAM_CHANNEL_TYPE]: byteStreamChannelHandler(options.localBaseUrl, options.log),
    [HTTP_CHANNEL_TYPE]: httpChannelHandler(options.localBaseUrl, options.log),
    [GATEWAY_CHANNEL_TYPE]: gatewayLoopbackHandler(
      options.localBaseUrl,
      options.log,
      options.fleetCallers
    ),
    [WS_CHANNEL_TYPE]: wsChannelHandler(options.localBaseUrl)
  }
  let connection: CloudMachineConnection | undefined
  const tunnel = await prepareMachineTunnel({
    credentialsPath: options.credentialsPath,
    deviceId: credentials.deviceId,
    secretKey: credentials.secretKey,
    channelHandlers,
    peerKeyPins,
    compressPayload,
    decompressPayload,
    sendAddr: (addr) => connection?.sendTunnelAddr(addr),
    defaultPathPolicy: managedBy === "app" ? "relay-only" : "auto",
    env: options.env,
    log: options.log
  })
  const icon = await options.icon
  connection = new CloudMachineConnection({
    credentials,
    ...(tunnel === undefined
      ? {}
      : {
          tunnelEndpointId: tunnel.endpointId,
          onTunnelConfig: tunnel.onTunnelConfig,
          onPeerDevices: tunnel.onPeerDevices
        }),
    peerKeyPins,
    relayCoalesceMs: RELAY_COALESCE_MS,
    compressPayload,
    decompressPayload,
    onPeerKeyMismatch: ({ deviceId, pinned, presented }) => {
      options.log(
        `Cloud: REFUSED channel from app device ${deviceId}: its key changed ` +
          `(pinned ${pinned}, presented ${presented}). If this is expected ` +
          `(e.g. the app or machine was reinstalled without its keys), remove the ` +
          `device's entry from ${peerPinsPath(options.credentialsPath)} and retry.`
      )
    },
    device: {
      name: machineName,
      os: process.platform,
      icon,
      appVersion: options.appVersion,
      ...(options.serverId === undefined ? {} : { serverId: options.serverId }),
      ...(options.releaseChannel === undefined ? {} : { releaseChannel: options.releaseChannel })
    },
    socketFactory,
    channelHandlers,
    onInboxItem: inboxFrameHandler(options.inbox, credentials.secretKey, (itemIds) =>
      connection?.ackInboxItems(itemIds)
    ),
    onWelcome: ({ resumed, replayedFrames }) => {
      if (resumed) {
        options.log(`Cloud: resumed relay session (${replayedFrames} held frames replayed)`)
      }
    },
    onStateChange: (state) => {
      if (state === "connected") options.log(`Cloud: connected to ${credentials.serverUrl}`)
      if (state === "reconnecting") options.log("Cloud: reconnecting to relay")
      if (state === "revoked") {
        options.log(
          "Cloud: the relay refused this machine's credential; re-checking every 5 minutes. " +
            "If this machine was removed from the account, run `codevisor auth logout` and then `codevisor auth login` to add it again."
        )
      }
      if (state === "unsupported-protocol") {
        options.log("Cloud: relay requires a newer server version; disconnecting.")
      }
    },
    onDisconnect: (reason) => {
      if (reason.kind === "socket-closed") {
        options.log(`Cloud: relay socket closed with code ${reason.code}`)
      } else if (reason.kind === "upgrade-rejected") {
        options.log(`Cloud: relay refused the connection with HTTP ${reason.status}`)
      } else if (reason.kind === "welcome-timeout") {
        options.log("Cloud: relay handshake timed out; replacing the socket")
      } else if (reason.kind === "heartbeat-timeout") {
        options.log("Cloud: relay heartbeat timed out; replacing the socket")
      } else {
        options.log(`Cloud: relay ${reason.phase} send failed; replacing the socket`)
      }
    }
  })
  connection.start()
  const directHost = new DirectChannelHost({
    deviceId: credentials.deviceId,
    secretKey: credentials.secretKey,
    channelHandlers,
    peerKeyPins,
    compressPayload,
    decompressPayload,
    log: options.log
  })
  const hubConnection = connection
  return {
    stop: () => {
      tunnel?.stop()
      hubConnection.stop()
    },
    state: () => hubConnection.state,
    deviceId: credentials.deviceId,
    serverUrl: credentials.serverUrl,
    managedBy,
    machineName,
    acceptDirect: (socket) => directHost.accept(socket),
    machines: () => connection.machines(),
    requestGateway: (deviceId, body, signal) =>
      requestOverGatewayChannel(
        () => connection.openChannel(deviceId, GATEWAY_CHANNEL_TYPE),
        body,
        signal === undefined ? {} : { signal }
      ),
    bridgeTunnelMedia: async (request, answer) => tunnel?.bridgeMedia(request, answer),
    setDirectPaths: (allowed) => tunnel?.setDirectPaths(allowed)
  }
}

export const startCloudBridge = async (
  options: CloudBridgeOptions
): Promise<CloudBridge | undefined> => {
  const stored = await readCredentials(options.credentialsPath)
  if (stored !== undefined) {
    const credentials = await validateOrReprovision(options, stored.credentials)
    return makeBridge(
      { ...options, machineName: stored.machineName ?? options.machineName },
      credentials,
      stored.managedBy,
      await loadPeerKeyPins(options)
    )
  }
  const provisioned = await devProvision(options)
  if (provisioned === undefined) return undefined
  return makeBridge(options, provisioned, "external", await loadPeerKeyPins(options))
}

export type CloudJoinGrant =
  | { readonly serverUrl: string; readonly sessionToken: string }
  | { readonly inviteCode: string }

export const connectCloudBridge = async (
  options: CloudBridgeOptions,
  params: CloudJoinGrant & {
    readonly managedBy?: CloudBridgeManagedBy
    readonly machineName?: string
  }
): Promise<CloudBridge> => {
  const managedBy = params.managedBy ?? "app"
  const bridgeOptions = { ...options, machineName: params.machineName ?? options.machineName }
  const fetchImpl = options.fetchImpl ?? ((input, init) => fetch(input, init))
  const machineName = bridgeOptions.machineName === "" ? hostname() : bridgeOptions.machineName
  let credentials: MachineCredentials
  if ("inviteCode" in params) {
    credentials = await redeemMachineInvite(fetchImpl, params.inviteCode, machineName)
  } else {
    credentials = await provisionMachine(
      fetchImpl,
      params.serverUrl.replace(/\/+$/, ""),
      params.sessionToken,
      machineName
    )
  }
  await writeFile(
    options.credentialsPath,
    JSON.stringify({ ...credentials, managedBy, machineName: params.machineName }, null, 2),
    {
      mode: 0o600
    }
  )
  return makeBridge(bridgeOptions, credentials, managedBy, await loadPeerKeyPins(options))
}

export const removeCloudCredentials = async (credentialsPath: string): Promise<void> => {
  await rm(credentialsPath, { force: true })
  await rm(peerPinsPath(credentialsPath), { force: true })
  await rm(tunnelPinsPath(credentialsPath), { force: true })
  await rm(tunnelKeyPath(credentialsPath), { force: true })
}

export const makeCloudServerControl = (
  options: CloudBridgeOptions,
  initial: CloudBridge | undefined
): CloudServerControl &
  Required<
    Pick<
      CloudServerControl,
      | "machineName"
      | "machines"
      | "requestGateway"
      | "connectWithInvite"
      | "invite"
      | "removePeer"
      | "setDirectPaths"
    >
  > => {
  let current = initial
  let connecting: Promise<string> | undefined
  let directPaths: boolean | undefined
  const fetchImpl = (): FetchLike => options.fetchImpl ?? ((input, init) => fetch(input, init))
  const joinCloud = (
    grant: CloudJoinGrant,
    registration: { readonly managedBy?: CloudBridgeManagedBy; readonly machineName?: string } = {}
  ): Promise<string> => {
    if (current !== undefined) return Promise.resolve(current.deviceId)
    connecting ??= connectCloudBridge(options, { ...grant, ...registration })
      .then((bridge) => {
        current = bridge
        if (directPaths !== undefined) bridge.setDirectPaths(directPaths)
        return bridge.deviceId
      })
      .finally(() => (connecting = undefined))
    return connecting
  }
  const storedCredentials = async (): Promise<MachineCredentials> => {
    let stored: StoredCloudCredentials | undefined
    if (current !== undefined) stored = await readCredentials(options.credentialsPath)
    if (stored === undefined) {
      throw new Error("This machine is not connected to a Codevisor Cloud account")
    }
    return stored.credentials
  }
  return {
    deviceId: () => current?.deviceId,
    state: () => current?.state(),
    serverUrl: () => current?.serverUrl,
    managedBy: () => current?.managedBy,
    machineName: () => current?.machineName,
    connect: (serverUrl, sessionToken, registration) =>
      joinCloud({ serverUrl, sessionToken }, registration),
    connectWithInvite: (inviteCode, registration) => joinCloud({ inviteCode }, registration),
    invite: async (inviteOptions) =>
      createMachineInvite(fetchImpl(), await storedCredentials(), inviteOptions),
    removePeer: async (deviceId) =>
      removeMachinePeer(fetchImpl(), await storedCredentials(), deviceId),
    machineRequest: async (method, path, body) =>
      machineApiRequest(fetchImpl(), await storedCredentials(), { method, path, body }),
    disconnect: async () => {
      current?.stop()
      current = undefined
      const stored = await readCredentials(options.credentialsPath)
      const removedFromAccount = await removeMachineFromCloudAccount(
        stored?.credentials,
        options.fetchImpl ?? ((input, init) => fetch(input, init)),
        options.log
      )
      await removeCloudCredentials(options.credentialsPath)
      return { removedFromAccount }
    },
    acceptDirect: (socket) => {
      if (current === undefined) return false
      current.acceptDirect(socket)
      return true
    },
    machines: () => current?.machines(),
    requestGateway: (deviceId, body, signal) => {
      if (current === undefined) {
        return Promise.reject(
          new GatewayChannelError("before-send", "not connected to the cloud relay")
        )
      }
      return current.requestGateway(deviceId, body, signal)
    },
    bridgeTunnelMedia: async (request, answer) => current?.bridgeTunnelMedia(request, answer),
    setDirectPaths: (allowed) => {
      directPaths = allowed
      return current?.setDirectPaths(allowed)
    }
  }
}

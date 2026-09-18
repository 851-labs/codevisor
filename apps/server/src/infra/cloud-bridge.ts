import { readFile, rm, writeFile } from "node:fs/promises"
import { hostname } from "node:os"
import { dirname, join } from "node:path"
import { deflateRawSync, inflateRawSync } from "node:zlib"

import {
  decode,
  TERMINAL_CHANNEL_TYPE,
  TerminalChannelParams,
  TerminalClientFrame,
  type TerminalServerFrame
} from "@codevisor/api"
import {
  BYTE_STREAM_CHANNEL_TYPE,
  CloudMachineConnection,
  DirectChannelHost,
  HTTP_CHANNEL_TYPE,
  makePeerKeyPinStore,
  parsePeerKeyPins,
  provisionMachine,
  serializePeerKeyPins,
  WS_CHANNEL_TYPE,
  type ChannelHandler,
  type CloudSocket,
  type MachineConnectionState,
  type MachineCredentials,
  type PeerKeyPinStore
} from "@codevisor/cloud-client"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { WebSocket } from "ws"

import type { CloudServerControl } from "../server-context-types.js"
import { byteStreamChannelHandler } from "./cloud-byte-stream.js"
import { httpChannelHandler, wsChannelHandler } from "./cloud-proxy-handlers.js"

/// Connects a running server to the user's cloud hub as a machine, serving
/// end-to-end encrypted terminal channels. Integration boundary over `ws`,
/// the filesystem, and live terminals — the protocol/reconnect/crypto logic
/// it composes is covered in @codevisor/cloud-client and @codevisor/cloud-crypto.

export interface CloudBridgeOptions {
  /// ${dataDir}/cloud.json — owned by this server for both native and CLI login.
  readonly credentialsPath: string
  readonly machineName: string
  readonly appVersion: string
  /// Loopback origin of this server's own HTTP API (http://127.0.0.1:port);
  /// structured request channels replay against it, while raw byte-stream
  /// channels connect only to this exact listener.
  readonly localBaseUrl: string
  readonly terminal: TerminalManagerService
  readonly env: Readonly<Record<string, string | undefined>>
  readonly log: (line: string) => void
}

/// Who created this machine's cloud registration. "app" registrations were
/// provisioned by the signed-in desktop app and follow its account session
/// (sign-out disconnects them); "external" ones came from `codevisor auth
/// login` or dev auto-provisioning and outlive the app's viewer session.
export type CloudBridgeManagedBy = "app" | "external"

export interface CloudBridge {
  readonly stop: () => void
  readonly state: () => MachineConnectionState
  /// This machine's cloud device id, advertised via /v1/info so clients can
  /// match the machine to its cloud presence entry.
  readonly deviceId: string
  readonly serverUrl: string
  readonly managedBy: CloudBridgeManagedBy
  /// Adopts one server-accepted WebSocket as a direct sealed-channel pipe:
  /// same channel handlers and pins as the relay, no hub in the middle.
  readonly acceptDirect: (socket: CloudSocket) => void
}

const readCredentials = async (
  path: string
): Promise<
  | { credentials: MachineCredentials; managedBy: CloudBridgeManagedBy; machineName?: string }
  | undefined
> => {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8")) as Partial<MachineCredentials> & {
      managedBy?: unknown
      machineName?: unknown
    }
    if (
      typeof parsed.serverUrl === "string" &&
      typeof parsed.deviceId === "string" &&
      typeof parsed.publicKey === "string" &&
      typeof parsed.secretKey === "string" &&
      typeof parsed.apiKey === "string"
    ) {
      return {
        credentials: parsed as MachineCredentials,
        managedBy: parsed.managedBy === "app" ? "app" : "external",
        ...(typeof parsed.machineName === "string" ? { machineName: parsed.machineName } : {})
      }
    }
    return undefined
  } catch {
    return undefined
  }
}

/// Dev environments auto-provision: dev.mjs signs into the local cloud and
/// hands servers a session token, so the local and Dev Remote machines appear
/// in the hub with zero manual `auth login`.
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

const socketFactory = (url: string, headers: Record<string, string>): CloudSocket => {
  const socket = new WebSocket(url, { headers })
  const adapted: CloudSocket = {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
    terminate: () => socket.terminate(),
    onopen: null,
    onmessage: null,
    onclose: null,
    onrejected: null
  }
  socket.on("open", () => adapted.onopen?.())
  // With a listener attached, ws leaves a non-101 response to us instead of
  // collapsing it into an error + close 1006. Surface the status, then drop
  // the request; any close ws still reports refers to a socket already
  // detached by the connection.
  socket.on("unexpected-response", (request, response) => {
    response.resume()
    request.destroy()
    adapted.onrejected?.(response.statusCode ?? 0)
  })
  socket.on("message", (data, isBinary) => {
    // Binary frames carry relay envelope batches; text frames JSON control.
    if (isBinary) {
      const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer)
      adapted.onmessage?.(new Uint8Array(bytes))
      return
    }
    adapted.onmessage?.(String(data))
  })
  socket.on("close", (code) => adapted.onclose?.(code))
  socket.on("error", () => undefined) // close fires afterwards and drives reconnect
  return adapted
}

/// Nagle for the relay: PTY writes and byte-stream chunks arrive in bursts,
/// and each envelope no longer has to be its own hub message (billed and
/// radio-waking). 5ms is far below any relay round trip.
const RELAY_COALESCE_MS = 5

/// Below this, DEFLATE overhead eats the win (and the CPU isn't worth it).
const COMPRESS_MIN_BYTES = 512

/// Raw DEFLATE for channels whose opener negotiated compressible framing:
/// terminal output and API/event JSON routinely shrink 3-10x. Skipped when
/// it would not actually shrink the payload (already-compressed data).
const compressPayload = (bytes: Uint8Array): Uint8Array | undefined => {
  if (bytes.byteLength < COMPRESS_MIN_BYTES) return undefined
  const deflated = deflateRawSync(bytes)
  return deflated.byteLength < bytes.byteLength ? new Uint8Array(deflated) : undefined
}

const decompressPayload = (bytes: Uint8Array): Uint8Array => new Uint8Array(inflateRawSync(bytes))

/// Serves one app-opened terminal channel: reattach via (terminalId,
/// sinceSeq), stream frames out, apply client frames in. Channel payloads:
/// app→machine TerminalClientFrame, machine→app TerminalServerFrame.
const terminalChannelHandler =
  (terminal: TerminalManagerService, log: (line: string) => void): ChannelHandler =>
  (channel) => {
    let detach: (() => void) | undefined
    let params: TerminalChannelParams
    try {
      params = decode(TerminalChannelParams)(channel.params)
    } catch {
      channel.close("rejected")
      return
    }
    const sink = (frame: TerminalServerFrame): void => channel.send(frame)
    Effect.runPromise(terminal.connectTerminal(params.terminalId, params.sinceSeq, sink))
      .then((unsubscribe) => {
        detach = unsubscribe
      })
      .catch((cause) => {
        log(`Cloud terminal channel rejected: ${cause instanceof Error ? cause.message : cause}`)
        channel.close("rejected")
      })
    channel.onData = (value) => {
      try {
        const frame = decode(TerminalClientFrame)(value)
        void Effect.runPromise(terminal.handleClientFrame(params.terminalId, frame)).catch(
          () => undefined
        )
      } catch {
        channel.close("protocol-error")
      }
    }
    channel.onClosed = () => detach?.()
  }

/// Dev self-heal: a local cloud reset (fresh D1) leaves the machine holding a
/// dead api key it would retry forever. When the dev env can mint fresh
/// credentials, probe the stored ones and re-provision if they're no longer
/// valid. Best-effort — an unreachable cloud keeps the stored credentials.
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

/// Where TOFU pins for app-device keys live, beside cloud.json. Deleting an
/// entry (or the file) is the manual recovery path for a stale pin.
const peerPinsPath = (credentialsPath: string): string =>
  join(dirname(credentialsPath), "cloud-peers.json")

/// Loads the persisted app-key pins into an in-memory store that writes back
/// (best-effort) whenever a new device is pinned.
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

/// Constructs and starts the relay connection for known-good credentials.
const makeBridge = (
  options: CloudBridgeOptions,
  credentials: MachineCredentials,
  managedBy: CloudBridgeManagedBy,
  peerKeyPins: PeerKeyPinStore
): CloudBridge => {
  // Shared by the relay connection and the direct pipe: a channel behaves
  // identically no matter which pipe carried it.
  const channelHandlers = {
    [BYTE_STREAM_CHANNEL_TYPE]: byteStreamChannelHandler(options.localBaseUrl, options.log),
    [TERMINAL_CHANNEL_TYPE]: terminalChannelHandler(options.terminal, options.log),
    [HTTP_CHANNEL_TYPE]: httpChannelHandler(options.localBaseUrl, options.log),
    [WS_CHANNEL_TYPE]: wsChannelHandler(options.localBaseUrl)
  }
  const connection = new CloudMachineConnection({
    credentials,
    peerKeyPins,
    relayCoalesceMs: RELAY_COALESCE_MS,
    compressPayload,
    decompressPayload,
    onPeerKeyMismatch: ({ deviceId, pinned, presented }) => {
      options.log(
        `Cloud: REFUSED channel from app device ${deviceId}: its key changed ` +
          `(pinned ${pinned}, presented ${presented}). If this is expected ` +
          `(e.g. the app was reinstalled without its keychain), remove the ` +
          `device's entry from ${peerPinsPath(options.credentialsPath)} and retry.`
      )
    },
    device: {
      name: options.machineName === "" ? hostname() : options.machineName,
      os: process.platform,
      appVersion: options.appVersion
    },
    socketFactory,
    channelHandlers,
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
          "Cloud: the relay no longer accepts this machine's credential; disconnecting. " +
            "Reconnect from Settings › Cloud or run `codevisor auth login`."
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
  return {
    stop: () => connection.stop(),
    state: () => connection.state,
    deviceId: credentials.deviceId,
    serverUrl: credentials.serverUrl,
    managedBy,
    acceptDirect: (socket) => directHost.accept(socket)
  }
}

/// Starts the bridge when credentials exist (stored, or dev auto-provision).
/// Returns undefined when this machine is not connected to a cloud account.
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

/// Registers this machine on the signed-in user's account and starts the
/// bridge immediately — the desktop app calls this (via POST
/// /v1/cloud/connect) after cloud sign-in so the local machine appears on the
/// account without a separate `codevisor auth login`. The stored credential
/// is tagged app-managed so sign-out knows it may disconnect it.
export const connectCloudBridge = async (
  options: CloudBridgeOptions,
  params: {
    readonly serverUrl: string
    readonly sessionToken: string
    readonly managedBy?: CloudBridgeManagedBy
    readonly machineName?: string
  }
): Promise<CloudBridge> => {
  const serverUrl = params.serverUrl.replace(/\/+$/, "")
  const managedBy = params.managedBy ?? "app"
  const bridgeOptions = { ...options, machineName: params.machineName ?? options.machineName }
  const credentials = await provisionMachine(
    (input, init) => fetch(input, init),
    serverUrl,
    params.sessionToken,
    bridgeOptions.machineName === "" ? hostname() : bridgeOptions.machineName
  )
  await writeFile(
    options.credentialsPath,
    JSON.stringify({ ...credentials, managedBy, machineName: params.machineName }, null, 2),
    {
      mode: 0o600
    }
  )
  return makeBridge(bridgeOptions, credentials, managedBy, await loadPeerKeyPins(options))
}

/// Forgets this machine's stored cloud credential (the caller stops the
/// bridge). Revoking the api key server-side is the app's job — it holds the
/// account session; this machine only holds its own credential. App key pins
/// go with it: a disconnected machine starts its next pairing fresh.
export const removeCloudCredentials = async (credentialsPath: string): Promise<void> => {
  await rm(credentialsPath, { force: true })
  await rm(peerPinsPath(credentialsPath), { force: true })
}

/// Shared live registration owner for native and CLI callers.
export const makeCloudServerControl = (
  options: CloudBridgeOptions,
  initial: CloudBridge | undefined
): CloudServerControl => {
  let current = initial
  return {
    deviceId: () => current?.deviceId,
    state: () => current?.state(),
    serverUrl: () => current?.serverUrl,
    managedBy: () => current?.managedBy,
    connect: async (serverUrl, sessionToken, registration) => {
      const bridge = await connectCloudBridge(options, { serverUrl, sessionToken, ...registration })
      current?.stop()
      current = bridge
      return bridge.deviceId
    },
    disconnect: async () => {
      current?.stop()
      current = undefined
      await removeCloudCredentials(options.credentialsPath)
    },
    acceptDirect: (socket) => {
      if (current === undefined) return false
      current.acceptDirect(socket)
      return true
    }
  }
}

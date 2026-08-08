import { hostname } from "node:os"
import {
  decode,
  TERMINAL_CHANNEL_TYPE,
  TerminalChannelParams,
  TerminalClientFrame,
  type TerminalServerFrame
} from "@codevisor/api"
import {
  CloudMachineConnection,
  provisionMachine,
  type ChannelHandler,
  type CloudSocket,
  type MachineConnectionState,
  type MachineCredentials
} from "@codevisor/cloud-client"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { WebSocket } from "ws"
import { readFile, writeFile } from "node:fs/promises"
import {
  appendBodyChunk,
  chunkFrames,
  concatBodyBuffer,
  emptyBodyBuffer,
  encodeWsFrame,
  headFrame,
  HTTP_CHANNEL_TYPE,
  parseHttpChannelParams,
  parseHttpRequestFrame,
  parseWsChannelParams,
  parseWsFrame,
  sanitizeRequestHeaders,
  WS_CHANNEL_TYPE
} from "./cloud-proxy.js"

/// Connects a running server to the user's cloud hub as a machine, serving
/// end-to-end encrypted terminal channels. Integration boundary over `ws`,
/// the filesystem, and live terminals — the protocol/reconnect/crypto logic
/// it composes is fully covered in @codevisor/cloud-client and
/// @codevisor/cloud-crypto, and the credential file format in cli/cloud-auth.

export interface CloudBridgeOptions {
  /// ${dataDir}/cloud.json — written by `codevisor auth login`.
  readonly credentialsPath: string
  readonly machineName: string
  readonly appVersion: string
  /// Loopback origin of this server's own HTTP API (http://127.0.0.1:port);
  /// the generic "http"/"ws" channels replay app requests against it.
  readonly localBaseUrl: string
  readonly terminal: TerminalManagerService
  readonly env: Readonly<Record<string, string | undefined>>
  readonly log: (line: string) => void
}

export interface CloudBridge {
  readonly stop: () => void
  readonly state: () => MachineConnectionState
  /// This machine's cloud device id, advertised via /v1/info so clients can
  /// match the machine to its cloud presence entry.
  readonly deviceId: string
}

const readCredentials = async (path: string): Promise<MachineCredentials | undefined> => {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8")) as Partial<MachineCredentials>
    if (
      typeof parsed.serverUrl === "string" &&
      typeof parsed.deviceId === "string" &&
      typeof parsed.publicKey === "string" &&
      typeof parsed.secretKey === "string" &&
      typeof parsed.apiKey === "string"
    ) {
      return parsed as MachineCredentials
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
    onopen: null,
    onmessage: null,
    onclose: null
  }
  socket.on("open", () => adapted.onopen?.())
  socket.on("message", (data) => adapted.onmessage?.(String(data)))
  socket.on("close", (code) => adapted.onclose?.(code))
  socket.on("error", () => undefined) // close fires afterwards and drives reconnect
  return adapted
}

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

/// Serves one app-opened HTTP channel: buffer the sealed request body frames,
/// replay the request against the local server (loopback is exempt from token
/// auth, so the app's cloud bearer is stripped and never forwarded), then
/// stream the response back as head/chunk/end frames. Pure frame and header
/// logic lives in cloud-proxy.ts.
const httpChannelHandler =
  (localBaseUrl: string, log: (line: string) => void): ChannelHandler =>
  (channel) => {
    const params = parseHttpChannelParams(channel.params)
    if (params === undefined) {
      channel.close("rejected")
      return
    }
    const body = emptyBodyBuffer()
    let requestDone = false
    let channelClosed = false
    channel.onClosed = () => {
      channelClosed = true
    }
    const respond = async (): Promise<void> => {
      try {
        const bytes = concatBodyBuffer(body)
        const response = await fetch(localBaseUrl + params.path, {
          method: params.method,
          headers: sanitizeRequestHeaders(params.headers),
          ...(bytes.byteLength === 0 ? {} : { body: bytes })
        })
        if (channelClosed) {
          await response.body?.cancel()
          return
        }
        channel.send(headFrame(response.status, response.headers))
        const reader = response.body?.getReader()
        if (reader !== undefined) {
          for (;;) {
            const { done, value } = await reader.read()
            if (done) break
            if (channelClosed) {
              await reader.cancel()
              return
            }
            for (const frame of chunkFrames(value)) channel.send(frame)
          }
        }
        channel.send({ kind: "end" })
        channel.close("done")
      } catch (cause) {
        log(`Cloud http channel failed: ${cause instanceof Error ? cause.message : String(cause)}`)
        channel.close("rejected")
      }
    }
    channel.onData = (value) => {
      if (requestDone) return
      const frame = parseHttpRequestFrame(value)
      if (frame === undefined) {
        requestDone = true
        channel.close("rejected")
        return
      }
      if (frame.kind === "chunk") {
        if (!appendBodyChunk(body, frame.data)) {
          requestDone = true
          channel.close("rejected")
        }
        return
      }
      requestDone = true
      void respond()
    }
  }

/// Serves one app-opened WebSocket channel by bridging it onto the local
/// server's own WS endpoint. Frames arriving before the local socket opens
/// are queued; either side closing gracefully surfaces as close("done").
const wsChannelHandler =
  (localBaseUrl: string): ChannelHandler =>
  (channel) => {
    const params = parseWsChannelParams(channel.params)
    if (params === undefined) {
      channel.close("rejected")
      return
    }
    const socket = new WebSocket(localBaseUrl.replace(/^http/, "ws") + params.path)
    let opened = false
    const queued: (string | Uint8Array)[] = []
    socket.on("open", () => {
      opened = true
      for (const message of queued) socket.send(message)
      queued.length = 0
    })
    socket.on("message", (data, isBinary) => {
      const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer)
      channel.send(isBinary ? encodeWsFrame(new Uint8Array(bytes)) : encodeWsFrame(String(data)))
    })
    socket.on("close", () => channel.close("done"))
    socket.on("error", () => {
      // close fires afterwards; before open that would report "done" for a
      // websocket that never connected, so reject first (later closes no-op).
      if (!opened) channel.close("rejected")
    })
    channel.onData = (value) => {
      const frame = parseWsFrame(value)
      if (frame === undefined) {
        channel.close("protocol-error")
        socket.close()
        return
      }
      if (opened) socket.send(frame.data)
      else queued.push(frame.data)
    }
    channel.onClosed = () => socket.close()
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

/// Starts the bridge when credentials exist (stored, or dev auto-provision).
/// Returns undefined when this machine is not connected to a cloud account.
export const startCloudBridge = async (
  options: CloudBridgeOptions
): Promise<CloudBridge | undefined> => {
  const stored = await readCredentials(options.credentialsPath)
  const credentials =
    stored !== undefined
      ? await validateOrReprovision(options, stored)
      : await devProvision(options)
  if (credentials === undefined) return undefined
  const connection = new CloudMachineConnection({
    credentials,
    device: {
      name: options.machineName === "" ? hostname() : options.machineName,
      os: process.platform,
      appVersion: options.appVersion
    },
    socketFactory,
    channelHandlers: {
      [TERMINAL_CHANNEL_TYPE]: terminalChannelHandler(options.terminal, options.log),
      [HTTP_CHANNEL_TYPE]: httpChannelHandler(options.localBaseUrl, options.log),
      [WS_CHANNEL_TYPE]: wsChannelHandler(options.localBaseUrl)
    },
    onStateChange: (state) => {
      if (state === "connected") options.log(`Cloud: connected to ${credentials.serverUrl}`)
      if (state === "revoked") {
        options.log("Cloud: this machine's credential was revoked; disconnecting.")
      }
      if (state === "unsupported-protocol") {
        options.log("Cloud: relay requires a newer server version; disconnecting.")
      }
    }
  })
  connection.start()
  return {
    stop: () => connection.stop(),
    state: () => connection.state,
    deviceId: credentials.deviceId
  }
}

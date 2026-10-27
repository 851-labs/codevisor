import { X509Certificate } from "node:crypto"
import { request as httpRequest, type IncomingMessage } from "node:http"
import { request as httpsRequest, type RequestOptions } from "node:https"
import { createServer, isIP, type Server, type Socket } from "node:net"
import { StringDecoder } from "node:string_decoder"
import { connect as tlsConnect, type PeerCertificate } from "node:tls"

import { Option, Schema } from "effect"
import { createWebSocketStream, WebSocket } from "ws"

import { SandboxProviderError, type OutputStream } from "./provider.js"
import type {
  OrchardControllerInfo,
  OrchardExecOutcome,
  OrchardExecOutput,
  OrchardExecRequest,
  OrchardPortForward,
  OrchardVm,
  OrchardWorker,
  TartOrchardClient,
  TartOrchardCredentials
} from "./tart-orchard.js"

export const tartOrchardApiClient = (credentials: TartOrchardCredentials): TartOrchardClient => {
  const controller = orchardController(credentials)
  return {
    controllerInfo: async () =>
      controllerInfoFrom(decodeControllerInfo(await controller.json("GET", "controller/info"))),
    createVm: async (spec) => {
      await controller.json("POST", "vms", spec)
    },
    getVm: async (name) => {
      const body = await controller.jsonUnlessMissing("GET", vmPath(name))
      return body === undefined ? undefined : vmFrom(decodeVm(body))
    },
    listVms: async () => (decodeVms(await controller.json("GET", "vms")) ?? []).map(vmFrom),
    deleteVm: async (name) => {
      await controller.jsonUnlessMissing("DELETE", vmPath(name))
    },
    listWorkers: async () =>
      (decodeWorkers(await controller.json("GET", "workers")) ?? []).map(workerFrom),
    exec: (name, request) => runExec(controller, name, request),
    forwardPort: (name, port) => forwardLocalPort(controller, name, port)
  }
}

interface Reply {
  readonly status: number
  readonly text: string
}

interface Trust {
  readonly ca?: string
  readonly servername?: string
}

interface OrchardController {
  readonly json: (method: string, path: string, body?: unknown) => Promise<unknown>
  readonly jsonUnlessMissing: (method: string, path: string) => Promise<unknown>
  readonly socket: (path: string, query: URLSearchParams, handshakeMs: number) => Promise<WebSocket>
}

const providerId = "tart-orchard"
const httpTimeoutMs = 30_000
const handshakeMarginMs = 15_000
const stdinChunkBytes = 16 * 1024
const outputLimitChars = 256_000
const loopbackHost = "127.0.0.1"
const forwardWaitSeconds = 60
const defaultHttpsPort = 443

const orchardController = (credentials: TartOrchardCredentials): OrchardController => {
  const base = new URL(credentials.controllerUrl)
  const authorization = basicAuthorization(credentials)
  const trust = retryingOnce(() => trustFor(base, credentials.certificateFingerprint))
  const endpoint = (path: string): URL =>
    new URL(`${base.pathname.replace(/\/+$/, "")}/v1/${path}`, base)
  const send = async (method: string, path: string, body?: unknown): Promise<Reply> =>
    sendRequest(endpoint(path), { method, authorization, trust: await trust(), body })
  return {
    json: async (method, path, body) => parsed(method, path, await send(method, path, body)),
    jsonUnlessMissing: async (method, path) => {
      const reply = await send(method, path)
      return reply.status === 404 ? undefined : parsed(method, path, reply)
    },
    socket: async (path, query, handshakeMs) =>
      newSocket(socketUrl(endpoint(path), query), {
        authorization,
        trust: await trust(),
        handshakeMs
      })
  }
}

const basicAuthorization = (credentials: TartOrchardCredentials): string => {
  const pair = `${credentials.serviceAccountName}:${credentials.serviceAccountToken}`
  return `Basic ${Buffer.from(pair, "utf8").toString("base64")}`
}

const retryingOnce = <T>(load: () => Promise<T>): (() => Promise<T>) => {
  let pending: Promise<T> | undefined
  return () => {
    pending ??= load().catch((cause: unknown) => {
      pending = undefined
      throw cause
    })
    return pending
  }
}

const vmPath = (name: string): string => `vms/${encodeURIComponent(name)}`

const socketUrl = (url: URL, query: URLSearchParams): URL => {
  const socket = new URL(url)
  socket.protocol = url.protocol === "http:" ? "ws:" : "wss:"
  socket.search = query.toString()
  return socket
}

interface SendOptions {
  readonly method: string
  readonly authorization: string
  readonly trust: Trust
  readonly body: unknown
}

const sendRequest = (url: URL, options: SendOptions): Promise<Reply> =>
  new Promise((resolve, reject) => {
    const payload = options.body === undefined ? undefined : JSON.stringify(options.body)
    const request = requestFor(url)(url, requestOptions(options, payload), (response) => {
      readReply(response).then(resolve, reject)
    })
    request.on("timeout", () => request.destroy(new Error("Orchard didn't answer in time")))
    request.on("error", reject)
    request.end(payload)
  })

const requestFor = (url: URL) => (url.protocol === "http:" ? httpRequest : httpsRequest)

const requestOptions = (options: SendOptions, payload: string | undefined): RequestOptions => ({
  method: options.method,
  timeout: httpTimeoutMs,
  headers: {
    Authorization: options.authorization,
    Accept: "application/json",
    ...(payload === undefined
      ? {}
      : { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) })
  },
  ...options.trust
})

const readReply = (response: IncomingMessage): Promise<Reply> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    response.on("data", (chunk: Buffer) => chunks.push(chunk))
    response.on("error", reject)
    response.on("end", () =>
      resolve({ status: response.statusCode ?? 0, text: Buffer.concat(chunks).toString("utf8") })
    )
  })

const parsed = (method: string, path: string, reply: Reply): unknown => {
  if (reply.status !== 200) throw apiFailure(`${method} /v1/${path}`, reply)
  return reply.text.trim() === "" ? undefined : JSON.parse(reply.text)
}

const apiFailure = (action: string, reply: Reply): SandboxProviderError =>
  new SandboxProviderError(
    providerId,
    `Orchard ${action} failed (HTTP ${reply.status})${detailOf(reply)}`
  )

const detailOf = (reply: Reply): string => {
  const message = Option.getOrUndefined(decodeErrorMessage(reply.text))?.message
  const detail = message ?? reply.text.trim()
  return detail === "" ? "" : `: ${detail}`
}

const trustFor = async (base: URL, fingerprint: string | undefined): Promise<Trust> => {
  if (fingerprint === undefined || base.protocol !== "https:") return {}

  const certificate = await presentedCertificate(base)
  if (fingerprintKey(certificate.fingerprint256) !== fingerprintKey(fingerprint)) {
    throw new SandboxProviderError(
      providerId,
      "The Orchard controller's certificate doesn't match the configured fingerprint"
    )
  }
  return { ca: new X509Certificate(certificate.raw).toString(), ...serverNameOf(certificate) }
}

const presentedCertificate = (base: URL): Promise<PeerCertificate> =>
  new Promise((resolve, reject) => {
    const host = base.hostname.replace(/^\[|\]$/g, "")
    const socket = tlsConnect(
      {
        host,
        port: base.port === "" ? defaultHttpsPort : Number(base.port),
        rejectUnauthorized: false,
        ...(isIP(host) === 0 ? { servername: host } : {})
      },
      () => {
        const certificate = socket.getPeerCertificate()
        socket.destroy()
        resolve(certificate)
      }
    )
    socket.setTimeout(httpTimeoutMs, () =>
      socket.destroy(new Error("Orchard didn't answer in time"))
    )
    socket.once("error", reject)
  })

const fingerprintKey = (value: string): string => value.replace(/[^0-9a-f]/gi, "").toUpperCase()

const serverNameOf = (certificate: PeerCertificate): Trust => {
  const dnsName = /DNS:([^,\s]+)/.exec(certificate.subjectaltname ?? "")?.[1]
  return dnsName === undefined ? {} : { servername: dnsName }
}

interface SocketOptions {
  readonly authorization: string
  readonly trust: Trust
  readonly handshakeMs: number
}

const newSocket = (url: URL, options: SocketOptions): WebSocket =>
  new WebSocket(url, {
    headers: { Authorization: options.authorization },
    handshakeTimeout: options.handshakeMs,
    ...options.trust
  })

const opened = (socket: WebSocket): Promise<void> =>
  new Promise((resolve, reject) => {
    socket.once("error", reject)
    socket.once("open", () => resolve())
    socket.once("unexpected-response", (request, response) => {
      readReply(response).then((reply) => {
        request.destroy()
        reject(apiFailure(`GET ${new URL(socket.url).pathname}`, reply))
      }, reject)
    })
  })

const runExec = async (
  controller: OrchardController,
  name: string,
  request: OrchardExecRequest
): Promise<OrchardExecOutcome> => {
  const socket = await controller.socket(
    `${vmPath(name)}/exec`,
    execQuery(request),
    Math.min(request.timeoutMs, request.waitSeconds * 1000 + handshakeMarginMs)
  )
  const session = execSession(socket, request.onOutput)
  await opened(socket)
  sendStdin(socket, request.stdin)
  return session.within(request.timeoutMs)
}

const execSession = (socket: WebSocket, onOutput: OrchardExecRequest["onOutput"]) => {
  const output = outputCollector(onOutput)
  const { promise, resolve } = Promise.withResolvers<OrchardExecOutcome>()
  const finish = (outcome: OrchardExecOutcome): void => {
    socket.close()
    resolve(outcome)
  }
  socket.on("message", (data, isBinary) => {
    if (!isBinary) handleFrame(frameText(data), output, finish)
  })
  socket.on("error", (cause) =>
    finish({ kind: "failed", message: cause.message, ...output.final() })
  )
  socket.on("close", () => finish({ kind: "failed", message: disconnected, ...output.final() }))
  return {
    within: async (timeoutMs: number): Promise<OrchardExecOutcome> => {
      const timer = setTimeout(() => finish({ kind: "timedOut", ...output.final() }), timeoutMs)
      try {
        return await promise
      } finally {
        clearTimeout(timer)
      }
    }
  }
}

const disconnected = "The Orchard controller closed the connection before the command finished"

const execQuery = (request: OrchardExecRequest): URLSearchParams => {
  const query = new URLSearchParams({ command: request.command, wait: String(request.waitSeconds) })
  if (request.stdin === undefined) return query

  query.set("interactive", "true")
  query.set("stdin", "true")
  return query
}

const sendStdin = (socket: WebSocket, stdin: string | undefined): void => {
  if (stdin === undefined) return

  const bytes = Buffer.from(stdin, "utf8")
  for (let offset = 0; offset < bytes.length; offset += stdinChunkBytes) {
    socket.send(stdinFrame(bytes.subarray(offset, offset + stdinChunkBytes)))
  }
  socket.send(stdinFrame(Buffer.alloc(0)))
}

const stdinFrame = (bytes: Buffer): string =>
  JSON.stringify({ type: "stdin", data: bytes.toString("base64") })

const outputCollector = (onOutput: OrchardExecRequest["onOutput"]) => {
  const decoders = { stdout: new StringDecoder("utf8"), stderr: new StringDecoder("utf8") }
  const text = { stdout: "", stderr: "" }
  const append = (stream: OutputStream, chunk: string): void => {
    text[stream] = (text[stream] + chunk).slice(-outputLimitChars)
    if (chunk !== "") onOutput?.(stream, chunk)
  }
  return {
    add: (stream: OutputStream, data: string): void =>
      append(stream, decoders[stream].write(Buffer.from(data, "base64"))),
    final: (): OrchardExecOutput => {
      append("stdout", decoders.stdout.end())
      append("stderr", decoders.stderr.end())
      return { stdout: text.stdout, stderr: text.stderr }
    }
  }
}

type OutputCollector = ReturnType<typeof outputCollector>

const handleFrame = (
  text: string,
  output: OutputCollector,
  finish: (outcome: OrchardExecOutcome) => void
): void => {
  const frame = Option.getOrUndefined(decodeFrame(text))
  if (frame === undefined) {
    finish({ kind: "failed", message: "Orchard sent an unreadable exec frame", ...output.final() })
    return
  }
  if (frame.type === "stdout" || frame.type === "stderr") output.add(frame.type, frame.data ?? "")
  if (frame.type === "exit") {
    finish({ kind: "exited", exitCode: frame.exit?.code ?? 1, ...output.final() })
  }
  if (frame.type === "error") {
    finish({ kind: "failed", message: frame.error ?? "unknown error", ...output.final() })
  }
}

const forwardLocalPort = (
  controller: OrchardController,
  name: string,
  port: number
): Promise<OrchardPortForward> =>
  new Promise((resolve, reject) => {
    const connections = new Set<Socket>()
    const server = createServer((local) => {
      connections.add(local)
      local.once("close", () => connections.delete(local))
      void bridge(controller, `${vmPath(name)}/port-forward`, port, local)
    })
    server.once("error", reject)
    server.listen(0, loopbackHost, () =>
      resolve({
        host: loopbackHost,
        port: listeningPort(server),
        close: () => closeServer(server, connections)
      })
    )
  })

const bridge = async (
  controller: OrchardController,
  path: string,
  port: number,
  local: Socket
): Promise<void> => {
  local.on("error", () => local.destroy())
  const query = new URLSearchParams({ port: String(port), wait: String(forwardWaitSeconds) })
  try {
    const socket = await controller.socket(
      path,
      query,
      forwardWaitSeconds * 1000 + handshakeMarginMs
    )
    const remote = createWebSocketStream(socket)
    remote.on("error", () => local.destroy())
    local.once("close", () => remote.destroy())
    local.pipe(remote).pipe(local)
  } catch {
    local.destroy()
  }
}

const listeningPort = (server: Server): number => {
  const address = server.address()
  return typeof address === "object" && address !== null ? address.port : 0
}

const closeServer = (server: Server, connections: Set<Socket>): Promise<void> =>
  new Promise((resolve) => {
    for (const connection of connections) connection.destroy()
    server.close(() => resolve())
  })

const Resources = Schema.optional(Schema.NullOr(Schema.Record(Schema.String, Schema.Number)))

const VmJson = Schema.Struct({
  name: Schema.String,
  status: Schema.optional(Schema.String),
  status_message: Schema.optional(Schema.String),
  worker: Schema.optional(Schema.String),
  resources: Resources
})

const WorkerJson = Schema.Struct({
  name: Schema.String,
  scheduling_paused: Schema.optional(Schema.Boolean),
  resources: Resources
})

const ControllerInfoJson = Schema.Struct({ version: Schema.optional(Schema.String) })

const ExecFrameJson = Schema.Struct({
  type: Schema.String,
  data: Schema.optional(Schema.String),
  exit: Schema.optional(Schema.Struct({ code: Schema.Number })),
  error: Schema.optional(Schema.String)
})

const ErrorJson = Schema.Struct({ message: Schema.String })

const decodeVm = Schema.decodeUnknownSync(VmJson)
const decodeVms = Schema.decodeUnknownSync(Schema.NullOr(Schema.Array(VmJson)))
const decodeWorkers = Schema.decodeUnknownSync(Schema.NullOr(Schema.Array(WorkerJson)))
const decodeControllerInfo = Schema.decodeUnknownSync(ControllerInfoJson)
const decodeFrame = Schema.decodeUnknownOption(Schema.fromJsonString(ExecFrameJson))
const decodeErrorMessage = Schema.decodeUnknownOption(Schema.fromJsonString(ErrorJson))

const vmFrom = (vm: typeof VmJson.Type): OrchardVm => ({
  name: vm.name,
  status: vm.status ?? "pending",
  resources: vm.resources ?? {},
  ...(vm.status_message === undefined ? {} : { statusMessage: vm.status_message }),
  ...(vm.worker === undefined ? {} : { worker: vm.worker })
})

const workerFrom = (worker: typeof WorkerJson.Type): OrchardWorker => ({
  name: worker.name,
  schedulingPaused: worker.scheduling_paused ?? false,
  resources: worker.resources ?? {}
})

const controllerInfoFrom = (info: typeof ControllerInfoJson.Type): OrchardControllerInfo =>
  info.version === undefined ? {} : { version: info.version }

const frameText = (data: WebSocket.RawData): string => {
  if (Buffer.isBuffer(data)) return data.toString("utf8")
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8")
  return Buffer.from(data).toString("utf8")
}

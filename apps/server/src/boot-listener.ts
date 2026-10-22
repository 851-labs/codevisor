import { createServer } from "node:http"
import type { IncomingMessage, Server, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import type { DataUpgradeProgress, HealthResponse } from "@codevisor/api"

import { claimPort, type LoopbackCheck } from "./infra/port-claim.js"

export interface BootListenerOptions {
  readonly host: string
  readonly candidates: ReadonlyArray<number>
  readonly loopbackIsOurs?: LoopbackCheck
  readonly version: string | undefined
  readonly bootId: string
  readonly processId: number
  readonly appOwned: boolean
  readonly serviceManaged: boolean
  readonly buildNumber?: number | undefined
  readonly sourceRevision?: string | undefined
  readonly log?: (line: string) => void
}

export interface BootListener {
  readonly server: Server
  readonly port: number
  readonly report: (progress: DataUpgradeProgress) => void
  readonly detach: () => void
  readonly close: (options?: { readonly afterMs?: number }) => Promise<void>
}

export const FAILED_UPGRADE_GRACE_MS = 10_000

const BOOT_REFUSED = JSON.stringify({ error: "Server is updating its data" })

const defaultLog = (line: string): void => console.error(line)

const onSocket = (_request: IncomingMessage, socket: Socket): void => {
  socket.destroy()
}

export const bootHealth = (
  options: BootListenerOptions,
  latest: DataUpgradeProgress | undefined
): HealthResponse => ({
  ok: false,
  version: options.version ?? "0.1.0",
  database: latest?.state === "failed" ? "failed" : "migrating",
  bootId: options.bootId,
  processId: options.processId,
  appOwned: options.appOwned,
  serviceManaged: options.serviceManaged,
  ...(options.buildNumber === undefined ? {} : { buildNumber: options.buildNumber }),
  ...(options.sourceRevision === undefined ? {} : { sourceRevision: options.sourceRevision }),
  ...(latest === undefined
    ? {}
    : {
        migration: {
          id: latest.id,
          name: latest.name,
          completed: latest.completed,
          total: latest.total,
          ...(latest.error === undefined ? {} : { error: latest.error })
        }
      })
})

export const claimBootListener = async (options: BootListenerOptions): Promise<BootListener> => {
  const log = options.log ?? defaultLog
  const progress: BootProgress = { latest: undefined }
  const onRequest = bootRequestHandler(options, progress)
  const onServerError = (error: Error): void => log(`Early health listener error: ${error.message}`)
  const server = createServer(onRequest)
  server.on("upgrade", onSocket)
  server.on("connect", onSocket)

  const port = await claimPort(server, options)
  server.on("error", onServerError)
  return {
    server,
    port,
    report: (next) => {
      progress.latest = next
    },
    detach: () => {
      server.off("request", onRequest)
      server.off("upgrade", onSocket)
      server.off("connect", onSocket)
      server.off("error", onServerError)
    },
    close: (closeOptions) => closeBootListener(server, closeOptions)
  }
}

interface BootProgress {
  latest: DataUpgradeProgress | undefined
}

const bootRequestHandler =
  (options: BootListenerOptions, progress: BootProgress) =>
  (request: IncomingMessage, response: ServerResponse): void => {
    if (request.method === "GET" && request.url?.split("?")[0] === "/v1/health") {
      response.writeHead(200, { "Content-Type": "application/json", Connection: "close" })
      response.end(JSON.stringify(bootHealth(options, progress.latest)))
      return
    }
    response.writeHead(503, { "Content-Type": "application/json", Connection: "close" })
    response.end(BOOT_REFUSED)
  }

const closeBootListener = async (
  server: Server,
  options: { readonly afterMs?: number } | undefined
): Promise<void> => {
  if (options?.afterMs !== undefined && options.afterMs > 0) {
    await new Promise<void>((done) => setTimeout(done, options.afterMs))
  }
  await new Promise<void>((done) => {
    server.close(() => done())
    server.closeAllConnections()
  })
}

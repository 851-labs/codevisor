import { createServer } from "node:http"
import type { IncomingMessage, Server, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import type { DataUpgradeProgress, HealthResponse } from "@codevisor/api"

import { hasExistingListener } from "./infra/listener-probe.js"

export interface BootListenerOptions {
  readonly host: string
  readonly port: number
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

export const startBootListenerIfPortFree = async (
  options: BootListenerOptions
): Promise<BootListener | undefined> => {
  if (options.port === 0) return undefined
  if (await hasExistingListener(options.host, options.port)) {
    const log = options.log ?? defaultLog
    log(
      `${options.host}:${options.port} already has a listener; skipping the early health listener`
    )
    return undefined
  }
  return startBootListener(options)
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

export const startBootListener = (
  options: BootListenerOptions
): Promise<BootListener | undefined> =>
  new Promise((resolve) => {
    const log = options.log ?? defaultLog
    let latest: DataUpgradeProgress | undefined
    const onRequest = (request: IncomingMessage, response: ServerResponse): void => {
      if (request.method === "GET" && request.url?.split("?")[0] === "/v1/health") {
        response.writeHead(200, { "Content-Type": "application/json", Connection: "close" })
        response.end(JSON.stringify(bootHealth(options, latest)))
        return
      }
      response.writeHead(503, { "Content-Type": "application/json", Connection: "close" })
      response.end(BOOT_REFUSED)
    }
    const server = createServer(onRequest)
    server.on("upgrade", onSocket)
    server.on("connect", onSocket)
    const onBindError = (error: Error): void => {
      log(`Early health listener unavailable on ${options.host}:${options.port}: ${error.message}`)
      resolve(undefined)
    }
    const onServerError = (error: Error): void => {
      log(`Early health listener error: ${error.message}`)
    }
    server.once("error", onBindError)
    server.listen(options.port, options.host, () => {
      server.off("error", onBindError)
      server.on("error", onServerError)
      resolve({
        server,
        report: (progress) => {
          latest = progress
        },
        detach: () => {
          server.off("request", onRequest)
          server.off("upgrade", onSocket)
          server.off("connect", onSocket)
          server.off("error", onServerError)
        },
        close: async (closeOptions) => {
          if (closeOptions?.afterMs !== undefined && closeOptions.afterMs > 0) {
            await new Promise<void>((done) => setTimeout(done, closeOptions.afterMs))
          }
          await new Promise<void>((done) => {
            server.close(() => done())
            server.closeAllConnections()
          })
        }
      })
    })
  })

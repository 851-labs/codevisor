import { createServer } from "node:http"
import type { IncomingMessage, Server, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import type { DataUpgradeProgress, HealthResponse } from "@codevisor/api"

import { hasExistingListener } from "./infra/listener-probe.js"

/// The server's listener, bound before the blocking data upgrades run.
///
/// Migrations complete before the real router exists, so without this a
/// migrating machine is simply unreachable and a remote client cannot tell
/// "updating chat history, 40%" from "hung". While booting, the listener
/// answers `/v1/health` with `ok: false`, `database: "migrating" | "failed"`
/// and the latest upgrade report; every other request is refused. Once the
/// services exist, `startCodevisorServer` detaches these handlers and takes
/// over the same socket, so clients never see a refused-connection gap.

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
  /// Records the newest upgrade report for the health answer.
  readonly report: (progress: DataUpgradeProgress) => void
  /// Removes the boot handlers so the real server can install its own.
  readonly detach: () => void
  /// Stops accepting and drops every open connection (failure path only).
  /// `afterMs` keeps answering that long first: a boot that failed its data
  /// upgrade is restarted by launchd/systemd within seconds, and a remote
  /// client polling every couple of seconds would otherwise only ever see
  /// the flap, never the reason.
  readonly close: (options?: { readonly afterMs?: number }) => Promise<void>
}

/// How long a boot that failed its data upgrade keeps answering /v1/health
/// with the failure before exiting.
export const FAILED_UPGRADE_GRACE_MS = 10_000

const BOOT_REFUSED = JSON.stringify({ error: "Server is updating its data" })

const defaultLog = (line: string): void => console.error(line)

/// Binds the boot listener unless something already serves the port — the
/// same shadow-bind guard the real start applies, so an accidental second
/// `serve` never hijacks a live server's clients with 503s. Ephemeral
/// ports (tests) skip it: nothing could be waiting on an unknown port.
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
  // Mirrors defaultServerConfig's fallback: dev runs have no VERSION file
  // and the client decodes `version` as a required string.
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

/// Binds the listener. Resolves undefined (after one log line) when the
/// port cannot be bound: the real start later is the authoritative check,
/// so an early bind failure must never fail boot on its own.
export const startBootListener = (
  options: BootListenerOptions
): Promise<BootListener | undefined> =>
  new Promise((resolve) => {
    const log = options.log ?? defaultLog
    let latest: DataUpgradeProgress | undefined
    const onRequest = (request: IncomingMessage, response: ServerResponse): void => {
      // Tokenless like the real health route; the payload carries nothing
      // about projects, sessions, or tokens. `Connection: close` keeps a
      // client from reusing this socket after the real server takes over.
      if (request.method === "GET" && request.url?.split("?")[0] === "/v1/health") {
        response.writeHead(200, { "Content-Type": "application/json", Connection: "close" })
        response.end(JSON.stringify(bootHealth(options, latest)))
        return
      }
      response.writeHead(503, { "Content-Type": "application/json", Connection: "close" })
      response.end(BOOT_REFUSED)
    }
    const onSocket = (_request: IncomingMessage, socket: Socket): void => {
      socket.destroy()
    }
    const server = createServer(onRequest)
    server.on("upgrade", onSocket)
    server.on("connect", onSocket)
    const onBindError = (error: Error): void => {
      log(`Early health listener unavailable on ${options.host}:${options.port}: ${error.message}`)
      resolve(undefined)
    }
    server.once("error", onBindError)
    server.listen(options.port, options.host, () => {
      server.off("error", onBindError)
      resolve({
        server,
        report: (progress) => {
          latest = progress
        },
        detach: () => {
          server.off("request", onRequest)
          server.off("upgrade", onSocket)
          server.off("connect", onSocket)
        },
        close: async (closeOptions) => {
          if (closeOptions?.afterMs !== undefined && closeOptions.afterMs > 0) {
            await new Promise<void>((done) => setTimeout(done, closeOptions.afterMs))
          }
          await new Promise<void>((done) => {
            // Stop accepting first, then drop what is open: a socket
            // accepted between the two calls would otherwise hold the
            // close callback until its request completed.
            server.close(() => done())
            server.closeAllConnections()
          })
        }
      })
    })
  })

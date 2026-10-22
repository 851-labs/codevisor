import type { Server } from "node:http"
import { createServer } from "node:net"

import { errorCode } from "../unknown-values.js"

export type LoopbackCheck = (port: number) => Promise<boolean>

export interface PortClaimOptions {
  readonly host: string
  readonly candidates: ReadonlyArray<number>
  readonly loopbackIsOurs?: LoopbackCheck
}

export const claimPort = async (server: Server, options: PortClaimOptions): Promise<number> => {
  const loopbackIsOurs = options.loopbackIsOurs ?? loopbackIsFreeOn(process.platform)
  for (const candidate of options.candidates) {
    const port = await listenUnlessTaken(server, options.host, candidate)
    if (port === undefined) continue

    if (!servesWildcard(options.host) || (await loopbackIsOurs(port))) return port
    await release(server)
  }
  throw new Error(unavailableMessage(options.host, options.candidates))
}

export const loopbackIsFreeOn =
  (platform: NodeJS.Platform): LoopbackCheck =>
  async (port) => {
    if (!WILDCARD_SHARING_PLATFORMS.has(platform)) return true

    const guard = createServer()
    const bound = await new Promise<boolean>((resolve) => {
      guard.once("error", () => resolve(false))
      guard.listen(port, LOOPBACK, () => resolve(true))
    })
    if (bound) await release(guard)
    return bound
  }

const LOOPBACK = "127.0.0.1"
const WILDCARD_HOSTS = new Set(["0.0.0.0", "::"])
const WILDCARD_SHARING_PLATFORMS = new Set<NodeJS.Platform>(["darwin", "freebsd", "openbsd"])

const servesWildcard = (host: string): boolean => WILDCARD_HOSTS.has(host)

const listenUnlessTaken = (
  server: Server,
  host: string,
  port: number
): Promise<number | undefined> =>
  new Promise((resolve, reject) => {
    const onError = (error: Error): void => {
      if (errorCode(error) === "EADDRINUSE") resolve(undefined)
      else reject(error)
    }
    server.once("error", onError)
    server.listen(port, host, () => {
      server.off("error", onError)
      resolve(boundPort(server, port))
    })
  })

const boundPort = (server: Server, requested: number): number => {
  const address = server.address()
  /* v8 ignore next */
  return typeof address === "object" && address !== null ? address.port : requested
}

const release = (server: { close: (done: () => void) => unknown }): Promise<void> =>
  new Promise((resolve) => {
    server.close(() => resolve())
  })

const unavailableMessage = (host: string, candidates: ReadonlyArray<number>): string => {
  if (candidates.length === 1) {
    return `${host}:${candidates[0]} already has a listener (another Codevisor server?). Stop the other process or pass a different --port.`
  }
  return `Every port Codevisor tried on ${host} is taken (${candidates.join(", ")})`
}

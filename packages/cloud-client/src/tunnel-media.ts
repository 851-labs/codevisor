import type { TunnelConnection, TunnelMediaFlow } from "@codevisor/net"

import type { CancelTimeout } from "./machine-socket.js"

const hostCandidate = (sdp: string): string | undefined => {
  for (const line of sdp.split(/\r?\n/)) {
    const match = /^a=candidate:\S+ \d+ udp \d+ (\d+\.\d+\.\d+\.\d+) (\d+) typ host\b/i.exec(line)
    if (match === null) continue
    const [, ip, port] = match
    if (ip!.startsWith("127.") || ip!.startsWith("169.254.")) continue
    return `${ip}:${port}`
  }
  return undefined
}

export interface TunnelMediaRequest {
  readonly endpointId: string
  readonly flowId: number
}

export interface TunnelMediaBridge {
  readonly flowId: number
  readonly maxPayload?: number
}

type MediaConnection = Pick<
  TunnelConnection,
  "remoteId" | "close" | "closed" | "forwardMedia" | "maxMediaPayload"
>

export interface TunnelMediaRoutesOptions {
  readonly admit: (endpointId: string) => boolean
  readonly scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  readonly waitMs?: number
  readonly log?: (line: string) => void
}

interface Route {
  connection: MediaConnection
  flows: TunnelMediaFlow[]
}

export class TunnelMediaRoutes {
  readonly #routes = new Map<string, Route>()
  readonly #waiters = new Map<string, ((route: Route | undefined) => void)[]>()

  constructor(private readonly options: TunnelMediaRoutesOptions) {}

  offer(connection: MediaConnection): void {
    const endpointId = connection.remoteId()
    if (!this.options.admit(endpointId)) {
      this.options.log?.(`Tunnel: refused media connection from unknown endpoint ${endpointId}`)
      connection.close(1, "not paired")
      return
    }
    this.#drop(endpointId)
    const route: Route = { connection, flows: [] }
    this.#routes.set(endpointId, route)
    void connection.closed().then(() => {
      if (this.#routes.get(endpointId) === route) this.#drop(endpointId)
    })
    for (const waiter of this.#waiters.get(endpointId) ?? []) waiter(route)
    this.#waiters.delete(endpointId)
  }

  async bridge(
    request: TunnelMediaRequest,
    answer: string
  ): Promise<TunnelMediaBridge | undefined> {
    const target = hostCandidate(answer)
    if (target === undefined) return undefined
    const route = this.#routes.get(request.endpointId) ?? (await this.#waitFor(request.endpointId))
    if (route === undefined) return undefined
    const flow = await route.connection.forwardMedia(request.flowId, target)
    route.flows.push(flow)
    const maxPayload = route.connection.maxMediaPayload()
    return { flowId: request.flowId, ...(maxPayload === null ? {} : { maxPayload }) }
  }

  #waitFor(endpointId: string): Promise<Route | undefined> {
    const schedule =
      this.options.scheduleTimeout ??
      ((callback: () => void, delayMs: number): CancelTimeout => {
        const timeout = setTimeout(callback, delayMs)
        return () => clearTimeout(timeout)
      })
    return new Promise((resolve) => {
      let cancel: CancelTimeout | undefined
      const waiter = (route: Route | undefined): void => {
        cancel?.()
        resolve(route)
      }
      const waiters = this.#waiters.get(endpointId) ?? []
      waiters.push(waiter)
      this.#waiters.set(endpointId, waiters)
      cancel = schedule(() => {
        const remaining = this.#waiters.get(endpointId)!.filter((entry) => entry !== waiter)
        if (remaining.length === 0) this.#waiters.delete(endpointId)
        else this.#waiters.set(endpointId, remaining)
        resolve(undefined)
      }, this.options.waitMs ?? 5_000)
    })
  }

  #drop(endpointId: string): void {
    const route = this.#routes.get(endpointId)
    if (route === undefined) return
    this.#routes.delete(endpointId)
    for (const flow of route.flows) flow.close()
    route.connection.close(0, "replaced")
  }
}

import type { TunnelConnection, TunnelMediaFlow } from "@codevisor/net"

import type { CancelTimeout } from "./machine-socket.js"

/// Screen-sharing media over the tunnel (docs/plans/codevisor-tunnel.md,
/// Phase 4). WebRTC keeps its own ICE/RTP/DTLS stack and sees the tunnel as a
/// LAN: the viewer opens a `codevisor/media/1` connection and a local UDP
/// flow, names both in its screen-sharing request, and the machine bridges
/// that flow to the host WebRTC's own candidate from the answer it produced.
/// ICE then completes over the flow (the host learns the forwarder as a
/// peer-reflexive candidate), and DTLS-SRTP runs end to end inside it.

/// The first IPv4 UDP host candidate in an SDP (`ip:port`), skipping loopback
/// and link-local — the socket the host's WebRTC actually listens on.
export const hostCandidate = (sdp: string): string | undefined => {
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
  /// The viewer's tunnel endpoint id (hex); its media connection is keyed by it.
  readonly endpointId: string
  readonly flowId: number
}

export interface TunnelMediaBridge {
  readonly flowId: number
  /// Largest UDP payload the flow carries now; the viewer caps RTP by it.
  readonly maxPayload?: number
}

type MediaConnection = Pick<
  TunnelConnection,
  "remoteId" | "close" | "closed" | "forwardMedia" | "maxMediaPayload"
>

export interface TunnelMediaRoutesOptions {
  /// Only endpoints already admitted on the channels pipe (pinned or vouched,
  /// see admitTunnelHello) may open media connections.
  readonly admit: (endpointId: string) => boolean
  readonly scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  /// How long `bridge` waits for the viewer's media connection to arrive.
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

  /// A media connection arrived (MachineTunnel's onMedia). A newer one from
  /// the same endpoint replaces the older one and its flows.
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

  /// Bridges the viewer's flow to the host's candidate from `answer`.
  /// Undefined when there is no usable candidate or the viewer's media
  /// connection never arrived — the viewer then keeps plain WebRTC ICE.
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
        // Still registered: offer() removes waiters only while cancelling this timer.
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

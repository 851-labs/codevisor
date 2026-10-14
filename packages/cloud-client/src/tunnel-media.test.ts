import type { TunnelMediaFlow } from "@codevisor/net"
import { describe, expect, it, vi } from "vitest"

import { TunnelMediaRoutes } from "./tunnel-media.js"

const answer = [
  "v=0",
  "a=candidate:1 1 udp 2122260223 127.0.0.1 50001 typ host generation 0",
  "a=candidate:2 1 udp 2122194687 169.254.3.4 50002 typ host generation 0",
  "a=candidate:3 1 tcp 1518280447 192.168.1.20 9 typ host tcptype active",
  "a=candidate:4 1 udp 2122129151 192.168.1.20 50004 typ host generation 0",
  "a=candidate:5 1 udp 1686052607 203.0.113.9 61000 typ srflx raddr 192.168.1.20 rport 50004"
].join("\r\n")

const mediaConnection = (endpointId: string) => {
  let finish!: () => void
  const closed = new Promise<string>((resolve) => {
    finish = () => resolve("closed")
  })
  const flows: { flowId: number; target: string; close: ReturnType<typeof vi.fn> }[] = []
  const connection = {
    remoteId: () => endpointId,
    close: vi.fn(),
    closed: () => closed,
    maxMediaPayload: () => 1150 as number | null,
    forwardMedia: async (flowId: number, target: string): Promise<TunnelMediaFlow> => {
      const flow = { flowId, target, close: vi.fn() }
      flows.push(flow)
      return { localPort: () => 40_000, close: flow.close }
    }
  }
  return { connection, flows, finish }
}

const scriptedTimeouts = () => {
  const pending: (() => void)[] = []
  return {
    schedule: (callback: () => void) => {
      pending.push(callback)
      return () => {
        const index = pending.indexOf(callback)
        if (index !== -1) pending.splice(index, 1)
      }
    },
    fireAll: () => {
      for (const callback of pending.splice(0)) callback()
    },
    get count() {
      return pending.length
    }
  }
}

describe("TunnelMediaRoutes", () => {
  it("bridges an admitted viewer's flow to the host's WebRTC candidate", async () => {
    const routes = new TunnelMediaRoutes({ admit: (id) => id === "viewer" })
    const viewer = mediaConnection("viewer")
    routes.offer(viewer.connection)
    expect(await routes.bridge({ endpointId: "viewer", flowId: 7 }, answer)).toEqual({
      flowId: 7,
      maxPayload: 1150
    })
    expect(viewer.flows.map(({ flowId, target }) => ({ flowId, target }))).toEqual([
      { flowId: 7, target: "192.168.1.20:50004" }
    ])
  })

  it("refuses media connections from endpoints the channels pipe never admitted", () => {
    const logs: string[] = []
    const routes = new TunnelMediaRoutes({ admit: () => false, log: (line) => logs.push(line) })
    const stranger = mediaConnection("stranger")
    routes.offer(stranger.connection)
    expect(stranger.connection.close).toHaveBeenCalledWith(1, "not paired")
    expect(logs).toEqual(["Tunnel: refused media connection from unknown endpoint stranger"])
  })

  it("waits for a media connection that arrives after the request", async () => {
    const timeouts = scriptedTimeouts()
    const routes = new TunnelMediaRoutes({ admit: () => true, scheduleTimeout: timeouts.schedule })
    const bridged = routes.bridge({ endpointId: "late", flowId: 1 }, answer)
    const late = mediaConnection("late")
    routes.offer(late.connection)
    expect(await bridged).toEqual({ flowId: 1, maxPayload: 1150 })
    expect(timeouts.count).toBe(0)
  })

  it("gives up when the media connection never arrives or there is no candidate", async () => {
    const timeouts = scriptedTimeouts()
    const routes = new TunnelMediaRoutes({ admit: () => true, scheduleTimeout: timeouts.schedule })
    const first = routes.bridge({ endpointId: "absent", flowId: 1 }, answer)
    const second = routes.bridge({ endpointId: "absent", flowId: 2 }, answer)
    timeouts.fireAll()
    expect(await first).toBeUndefined()
    expect(await second).toBeUndefined()
    const srflxOnly = "v=0\na=candidate:5 1 udp 1 203.0.113.9 61000 typ srflx"
    expect(await routes.bridge({ endpointId: "absent", flowId: 3 }, srflxOnly)).toBeUndefined()
    expect(timeouts.count).toBe(0)

    const unmeasured = mediaConnection("unmeasured")
    unmeasured.connection.maxMediaPayload = () => null
    routes.offer(unmeasured.connection)
    expect(await routes.bridge({ endpointId: "unmeasured", flowId: 4 }, answer)).toEqual({
      flowId: 4
    })
    expect(await routes.bridge({ endpointId: "unmeasured", flowId: 5 }, srflxOnly)).toBeUndefined()
    expect(unmeasured.flows.map(({ flowId }) => flowId)).toEqual([4])
  })

  it("uses the real timer by default, cancelling it once the connection arrives", async () => {
    vi.useFakeTimers()
    try {
      const routes = new TunnelMediaRoutes({ admit: () => true, waitMs: 1_000 })
      const bridged = routes.bridge({ endpointId: "slow", flowId: 1 }, answer)
      await vi.advanceTimersByTimeAsync(999)
      routes.offer(mediaConnection("slow").connection)
      expect(await bridged).toEqual({ flowId: 1, maxPayload: 1150 })
      expect(vi.getTimerCount()).toBe(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it("replaces an endpoint's older connection and cleans up when one closes", async () => {
    const routes = new TunnelMediaRoutes({ admit: () => true })
    const older = mediaConnection("viewer")
    routes.offer(older.connection)
    await routes.bridge({ endpointId: "viewer", flowId: 1 }, answer)
    const newer = mediaConnection("viewer")
    routes.offer(newer.connection)
    expect(older.flows[0]!.close).toHaveBeenCalledOnce()
    expect(older.connection.close).toHaveBeenCalledWith(0, "replaced")

    older.finish()
    await older.connection.closed()
    expect(newer.connection.close).not.toHaveBeenCalled()

    await routes.bridge({ endpointId: "viewer", flowId: 2 }, answer)
    newer.finish()
    await newer.connection.closed()
    expect(newer.flows[0]!.close).toHaveBeenCalledOnce()
  })
})

import { CLOUD_PROTOCOL_VERSION, GATEWAY_CHANNEL_TYPE } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import {
  gatewayChannelHandler,
  MAX_GATEWAY_BODY_CHARS,
  requestOverGatewayChannel,
  type GatewayExchange,
  type IncomingChannel,
  type OutgoingChannel
} from "./index.js"
import { failure, gatewayRequest, pair, presence, timers } from "./machine-peers-test-support.js"

describe("gateway exchanges between machines", () => {
  it("reports undelivered and refused requests as before-send", async () => {
    const { a, b, hub } = pair({ b: { handlers: {} } })
    expect((await failure(gatewayRequest(a, b, "{}"))).phase).toBe("before-send")

    hub.holding = true
    const undelivered = gatewayRequest(a, b, "{}")
    const channelId = a.socket.relayFrames().at(-1)!.channelId
    a.socket.receive({
      t: "error",
      code: "machine-offline",
      message: "machine relay delivery failed",
      machineId: "b",
      channelId
    })
    const error = await failure(undelivered)
    expect(error).toMatchObject({ phase: "before-send", reason: "undeliverable" })
  })

  it("reports losses after the target accepted as in-flight", async () => {
    const answers: PromiseWithResolvers<GatewayExchange>[] = []
    const handle = vi.fn(() => {
      const answer = Promise.withResolvers<GatewayExchange>()
      answers.push(answer)
      return answer.promise
    })
    const { a, b, hub } = pair({ b: { handle } })
    try {
      const offline = gatewayRequest(a, b, "{}")
      hub.flush()
      expect(handle).toHaveBeenCalledTimes(1)
      a.socket.receive({ t: "machine-reset", machineId: "c" })
      a.socket.receive({
        t: "error",
        code: "machine-offline",
        message: "machine relay delivery failed",
        machineId: "b",
        channelId: "unknown"
      })
      a.socket.receive({ t: "presence", machine: presence(b, false) })
      expect(await failure(offline)).toMatchObject({ phase: "in-flight", reason: "peer-gone" })

      a.socket.receive({ t: "presence", machine: presence(b) })
      const reset = gatewayRequest(a, b, "{}")
      hub.flush()
      expect(handle).toHaveBeenCalledTimes(2)
      a.socket.receive({ t: "machine-reset", machineId: "b" })
      expect((await failure(reset)).phase).toBe("in-flight")

      const hubWide = gatewayRequest(a, b, "{}")
      hub.flush()
      expect(handle).toHaveBeenCalledTimes(3)
      a.socket.receive({ t: "error", code: "machine-offline", message: "gone", machineId: "b" })
      expect((await failure(hubWide)).phase).toBe("in-flight")

      const lost = gatewayRequest(a, b, "{}")
      hub.flush()
      expect(handle).toHaveBeenCalledTimes(4)
      a.socket.onclose?.(1006)
      expect(await failure(lost)).toMatchObject({ phase: "in-flight", reason: "connection-lost" })
    } finally {
      for (const answer of answers) answer.resolve({ status: 200, body: "late" })
      await Promise.all(answers.map((answer) => answer.promise))
      hub.flush()
    }
  })

  it("keeps outgoing channels across a resumed relay session", async () => {
    const { a, b } = pair()
    a.socket.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: a.connectionId,
      resume: "token",
      machines: [presence(a), presence(b)]
    })
    a.socket.onclose?.(1006)
    const pending = gatewayRequest(a, b, "held")
    a.h.reconnects.at(-1)!.callback()
    const resumed = a.h.sockets.at(-1)!
    resumed.onRelay = a.socket.onRelay
    b.socket.onRelay = (envelopes) => {
      for (const { header, payload } of envelopes) {
        resumed.receiveRelay({ machineId: "b", frame: header.frame }, payload)
      }
    }
    resumed.onopen?.()
    resumed.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: a.connectionId,
      resumed: true,
      machines: [presence(a), presence(b)]
    })
    expect(await pending).toEqual({ status: 200, body: "HELD" })
  })

  it("cancels the target's handler when the caller aborts", async () => {
    let targetSignal: AbortSignal | undefined
    const { a, b } = pair({
      b: {
        handle: (_request, signal) => {
          targetSignal = signal
          return new Promise<GatewayExchange>(() => undefined)
        }
      }
    })
    const controller = new AbortController()
    const pending = gatewayRequest(a, b, "{}", { signal: controller.signal })
    controller.abort(new Error("stop"))
    await expect(pending).rejects.toThrow("stop")
    expect(targetSignal?.aborted).toBe(true)
    expect(a.socket.closeFrames()[0]!.reason).toBe("done")

    const already = new AbortController()
    already.abort(new Error("early"))
    await expect(gatewayRequest(a, b, "{}", { signal: already.signal })).rejects.toThrow("early")
  })

  it("gives up when the target never answers", async () => {
    const { a, b, hub } = pair()
    hub.holding = true
    const clock = timers()
    const pending = gatewayRequest(a, b, "{}", {
      scheduleTimeout: clock.scheduleTimeout,
      acceptTimeoutMs: 1000
    })
    expect(clock.pending.map((timer) => timer.delayMs)).toEqual([1000])
    clock.pending[0]!.callback()
    expect(await failure(pending)).toMatchObject({ phase: "in-flight" })
    expect(a.socket.lastClose().reason).toBe("done")
  })

  it("answers handler failures and refuses malformed requests on the target", async () => {
    const failures: unknown[] = [new Error("boom"), "bare"]
    const { a, b, hub } = pair({
      b: {
        handle: async () => {
          throw failures.shift()
        }
      }
    })
    for (const message of ["boom", "bare"]) {
      expect(await gatewayRequest(a, b, "{}")).toEqual({
        status: 502,
        body: JSON.stringify({ error: { message } })
      })
    }
    const early = await requestOverGatewayChannel(() => {
      const channel = a.h.connection.openChannel("b", GATEWAY_CHANNEL_TYPE)
      channel.send({ kind: "end" })
      return channel
    }, "ignored")
    expect(early.status).toBe(502)
    const refused = (...frames: unknown[]): unknown[] => {
      const ends: unknown[] = []
      const raw = a.h.connection.openChannel("b", GATEWAY_CHANNEL_TYPE)
      raw.onEnded = (end) => ends.push(end)
      for (const frame of frames) raw.send(frame)
      raw.send({ kind: "end" })
      hub.flush()
      return ends
    }
    const rejected = [{ kind: "peer-closed", reason: "rejected" }]
    expect(refused({ kind: "nonsense" })).toEqual(rejected)
    expect(refused(5)).toEqual(rejected)
    await expect(gatewayRequest(a, b, "x".repeat(MAX_GATEWAY_BODY_CHARS + 1))).rejects.toThrow(
      "request too large"
    )
  })
})

describe("gateway responder over a scripted channel", () => {
  it("refuses a request that grows past the body cap", () => {
    const sent: unknown[] = []
    const closes: string[] = []
    const handle = vi.fn(async () => ({ status: 200, body: "" }))
    const channel: IncomingChannel = {
      channelId: "ch",
      peerId: "peer",
      peer: { publicKey: "peer-key" },
      channelType: GATEWAY_CHANNEL_TYPE,
      params: undefined,
      flowControlRequested: false,
      send: (value) => sent.push(value),
      sendBytes: () => undefined,
      deferInboundCredit: () => undefined,
      grantCredit: () => undefined,
      queuedOutboundBytes: () => 0,
      close: (reason) => closes.push(reason),
      onData: null,
      onBytes: null,
      onCredit: null,
      onOutboundDrain: null,
      onClosed: null
    }
    gatewayChannelHandler(handle, () => undefined)(channel)
    channel.onData?.({ kind: "chunk", data: "x".repeat(MAX_GATEWAY_BODY_CHARS) }, 0)
    expect(closes).toEqual([])
    channel.onData?.({ kind: "chunk", data: "x" }, 0)
    channel.onData?.({ kind: "end" }, 0)
    expect(closes).toEqual(["rejected"])
    expect(sent).toEqual([])
    expect(handle).not.toHaveBeenCalled()
  })
})

const scriptedChannel = () => {
  const sent: unknown[] = []
  const closes: string[] = []
  const channel: OutgoingChannel = {
    channelId: "ch",
    machineId: "b",
    send: (value) => sent.push(value),
    close: (reason = "done") => closes.push(reason),
    onData: null,
    onEnded: null
  }
  return { channel, sent, closes }
}

describe("gateway exchange over a scripted channel", () => {
  it.each([
    ["a non-object", 7],
    ["an unknown kind", { kind: "mystery" }],
    ["a chunk without data", { kind: "chunk" }]
  ])("closes the channel on %s answer", async (_label, frame) => {
    const { channel, closes } = scriptedChannel()
    const pending = requestOverGatewayChannel(() => channel, "{}", {
      scheduleTimeout: timers().scheduleTimeout
    })
    channel.onData?.(frame)
    expect(await failure(pending)).toMatchObject({ phase: "in-flight", reason: "malformed answer" })
    expect(closes).toEqual(["protocol-error"])
  })

  it("stops reading an oversized answer and ignores frames after settling", async () => {
    const { channel, closes } = scriptedChannel()
    const pending = requestOverGatewayChannel(() => channel, "{}", {
      scheduleTimeout: timers().scheduleTimeout
    })
    channel.onData?.({ kind: "accepted" })
    channel.onData?.({ kind: "chunk", data: "x".repeat(MAX_GATEWAY_BODY_CHARS + 1) })
    expect(await failure(pending)).toMatchObject({ reason: "answer too large" })
    channel.onData?.({ kind: "end", status: 200 })
    channel.onEnded?.({ kind: "peer-gone" })
    expect(closes).toEqual(["done"])
  })

  it("reports a responder protocol violation as in-flight", async () => {
    const { channel } = scriptedChannel()
    const pending = requestOverGatewayChannel(() => channel, "{}", {
      scheduleTimeout: timers().scheduleTimeout
    })
    channel.onEnded?.({ kind: "protocol-error" })
    expect(await failure(pending)).toMatchObject({ phase: "in-flight", reason: "protocol-error" })
  })

  it("defaults to the global timer and clears it on acceptance or settling", async () => {
    vi.useFakeTimers()
    try {
      const accepted = scriptedChannel()
      const streamed = requestOverGatewayChannel(() => accepted.channel, "{}")
      expect(vi.getTimerCount()).toBe(1)
      accepted.channel.onData?.({ kind: "accepted" })
      expect(vi.getTimerCount()).toBe(0)
      accepted.channel.onData?.({ kind: "end", status: 200 })
      expect(await streamed).toEqual({ status: 200, body: "" })

      const ended = scriptedChannel()
      const pending = requestOverGatewayChannel(() => ended.channel, "{}")
      expect(vi.getTimerCount()).toBe(1)
      ended.channel.onData?.({ kind: "end", status: 204 })
      expect(await pending).toEqual({ status: 204, body: "" })
      expect(vi.getTimerCount()).toBe(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it("maps non-Error open failures", async () => {
    const pending = requestOverGatewayChannel(() => {
      throw "nope"
    }, "{}")
    expect(await failure(pending)).toMatchObject({ phase: "before-send", reason: "nope" })
  })
})

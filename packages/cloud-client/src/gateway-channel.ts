import { isRecord } from "@codevisor/api"
import type { ChannelCloseReason } from "@codevisor/api"

import type { OutgoingChannel, OutgoingChannelEnd } from "./channel-opener.js"
import type { ChannelHandler, ChannelPeer } from "./incoming-channel.js"
import { ChannelOpenError } from "./machine-peers.js"
import type { CancelTimeout } from "./machine-socket.js"

export const GATEWAY_CHUNK_CHARS = 128 * 1024
export const MAX_GATEWAY_BODY_CHARS = 32 * 1024 * 1024
export const GATEWAY_ACCEPT_TIMEOUT_MS = 20_000
export const GATEWAY_PROBE_INTERVAL_MS = 15_000
const GATEWAY_UNANSWERED_PROBES = 2

export interface GatewayExchange {
  readonly status: number
  readonly body: string
}

export type GatewayChannelPhase = "before-send" | "in-flight"

export class GatewayChannelError extends Error {
  override readonly name = "GatewayChannelError"
  constructor(
    readonly phase: GatewayChannelPhase,
    readonly reason: string,
    readonly closeReason?: ChannelCloseReason
  ) {
    super(`gateway channel failed ${phase}: ${reason}`)
  }
}

const chunks = (text: string): string[] => {
  const parts: string[] = []
  for (let offset = 0; offset < text.length; offset += GATEWAY_CHUNK_CHARS) {
    parts.push(text.slice(offset, offset + GATEWAY_CHUNK_CHARS))
  }
  return parts
}

const REFUSALS: ReadonlySet<string> = new Set(["unsupported", "rejected", "crypto-error"])

const endedBeforeSend = (end: OutgoingChannelEnd, accepted: boolean): boolean => {
  if (accepted) return false
  if (end.kind === "undeliverable") return true
  return end.kind === "peer-closed" && REFUSALS.has(end.reason)
}

const describeEnd = (end: OutgoingChannelEnd): string =>
  end.kind === "peer-closed" ? `closed by the target (${end.reason})` : end.kind

type Schedule = (callback: () => void, delayMs: number) => CancelTimeout

interface AnswerWatch {
  readonly heard: () => void
  readonly start: (answersProbes: boolean) => void
  readonly stop: () => void
}

const watchForAnswer = (
  channel: OutgoingChannel,
  schedule: Schedule,
  intervalMs: number,
  lost: () => void
): AnswerWatch => {
  let cancel: CancelTimeout | undefined
  let answersProbes = false
  let unanswered = 0
  const probe = (): void => {
    if (answersProbes && unanswered >= GATEWAY_UNANSWERED_PROBES) {
      lost()
      return
    }
    unanswered += 1
    channel.send({ kind: "probe" })
    cancel = schedule(probe, intervalMs)
  }
  return {
    heard: () => {
      unanswered = 0
    },
    start: (answers) => {
      answersProbes = answers
      cancel = schedule(probe, intervalMs)
    },
    stop: () => {
      cancel?.()
      cancel = undefined
    }
  }
}

export interface GatewayRequestOptions {
  readonly signal?: AbortSignal
  readonly acceptTimeoutMs?: number
  readonly probeIntervalMs?: number
  readonly scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
}

export const requestOverGatewayChannel = (
  open: () => OutgoingChannel,
  body: string,
  options: GatewayRequestOptions = {}
): Promise<GatewayExchange> =>
  new Promise<GatewayExchange>((resolve, reject) => {
    const { signal } = options
    if (signal?.aborted === true) {
      reject(signal.reason)
      return
    }
    if (body.length > MAX_GATEWAY_BODY_CHARS) {
      reject(new GatewayChannelError("before-send", "request too large"))
      return
    }
    let channel: OutgoingChannel
    try {
      channel = open()
    } catch (cause) {
      reject(
        new GatewayChannelError(
          "before-send",
          cause instanceof Error ? cause.message : String(cause),
          cause instanceof ChannelOpenError && cause.reason === "machine-outdated"
            ? "unsupported"
            : undefined
        )
      )
      return
    }
    let accepted = false
    let response = ""
    let settled = false
    const schedule =
      options.scheduleTimeout ??
      ((callback: () => void, delayMs: number): CancelTimeout => {
        const timer = setTimeout(callback, delayMs)
        return () => clearTimeout(timer)
      })
    const settle = (): boolean => {
      if (settled) return false
      settled = true
      cancelAcceptTimeout?.()
      watch.stop()
      signal?.removeEventListener("abort", onAbort)
      return true
    }
    const fail = (error: unknown, closeReason?: "done" | "protocol-error"): void => {
      if (!settle()) return
      if (closeReason !== undefined) channel.close(closeReason)
      reject(error)
    }
    const onAbort = (): void => fail(signal!.reason, "done")
    const watch = watchForAnswer(
      channel,
      schedule,
      options.probeIntervalMs ?? GATEWAY_PROBE_INTERVAL_MS,
      () => fail(new GatewayChannelError("in-flight", "the target stopped answering"), "done")
    )
    let cancelAcceptTimeout: CancelTimeout | undefined = schedule(() => {
      cancelAcceptTimeout = undefined
      fail(new GatewayChannelError("in-flight", "the target did not answer"), "done")
    }, options.acceptTimeoutMs ?? GATEWAY_ACCEPT_TIMEOUT_MS)
    signal?.addEventListener("abort", onAbort, { once: true })
    channel.onEnded = (end) => {
      fail(
        new GatewayChannelError(
          endedBeforeSend(end, accepted) ? "before-send" : "in-flight",
          describeEnd(end),
          end.kind === "peer-closed" ? end.reason : undefined
        )
      )
    }
    channel.onData = (value) => {
      if (!isRecord(value)) {
        fail(new GatewayChannelError("in-flight", "malformed answer"), "protocol-error")
        return
      }
      watch.heard()
      if (value.kind === "accepted") {
        accepted = true
        cancelAcceptTimeout?.()
        cancelAcceptTimeout = undefined
        watch.start(value.probes === true)
        return
      }
      if (value.kind === "working") return
      if (value.kind === "chunk" && typeof value.data === "string") {
        response += value.data
        if (response.length <= MAX_GATEWAY_BODY_CHARS) return
        fail(new GatewayChannelError("in-flight", "answer too large"), "done")
        return
      }
      if (value.kind === "end" && typeof value.status === "number") {
        if (settle()) resolve({ status: value.status, body: response })
        return
      }
      fail(new GatewayChannelError("in-flight", "malformed answer"), "protocol-error")
    }
    for (const data of chunks(body)) channel.send({ kind: "chunk", data })
    channel.send({ kind: "end" })
  })

export const gatewayChannelHandler =
  (
    handle: (request: string, signal: AbortSignal, peer: ChannelPeer) => Promise<GatewayExchange>,
    log: (line: string) => void
  ): ChannelHandler =>
  (channel) => {
    const controller = new AbortController()
    let request = ""
    let started = false
    channel.onClosed = () => controller.abort(new Error("the caller cancelled the request"))
    channel.onData = (value) => {
      if (started) {
        if (isRecord(value) && value.kind === "probe") channel.send({ kind: "working" })
        return
      }
      if (isRecord(value) && value.kind === "chunk" && typeof value.data === "string") {
        request += value.data
        if (request.length <= MAX_GATEWAY_BODY_CHARS) return
      } else if (isRecord(value) && value.kind === "end") {
        started = true
        channel.send({ kind: "accepted", probes: true })
        void run()
        return
      }
      started = true
      channel.close("rejected")
    }
    const run = async (): Promise<void> => {
      let answer: GatewayExchange
      try {
        answer = await handle(request, controller.signal, channel.peer)
      } catch (cause) {
        const message = cause instanceof Error ? cause.message : String(cause)
        log(`Gateway channel request failed: ${message}`)
        answer = { status: 502, body: JSON.stringify({ error: { message } }) }
      }
      for (const data of chunks(answer.body)) channel.send({ kind: "chunk", data })
      channel.send({ kind: "end", status: answer.status })
      channel.close("done")
    }
  }

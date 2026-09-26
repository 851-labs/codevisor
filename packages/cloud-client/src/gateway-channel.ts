import type { ChannelCloseReason } from "@codevisor/api"

import type { OutgoingChannel, OutgoingChannelEnd } from "./channel-opener.js"
import type { ChannelHandler } from "./incoming-channel.js"
import { ChannelOpenError } from "./machine-peers.js"
import type { CancelTimeout } from "./machine-socket.js"

/// One request/response exchange per GATEWAY_CHANNEL_TYPE channel: the way
/// a machine runs a Codevisor gateway call on another machine through the
/// hub. Bodies are opaque text (the server sends POST /v1/gateway/invoke JSON)
/// split into frames that stay far below the relay's message cap.
///
/// Opener → responder: `{kind:"chunk",data}`* then `{kind:"end"}`.
/// Responder → opener: `{kind:"accepted"}` once the whole request arrived and
///   the handler starts, then `{kind:"chunk",data}`* and
///   `{kind:"end",status}`, then close "done".
/// The opener closes the channel to cancel; the responder aborts its handler.

/// Characters per chunk frame (≤ 3 bytes each in UTF-8, far under the cap).
export const GATEWAY_CHUNK_CHARS = 128 * 1024
/// Upper bound for either body; larger exchanges are refused.
export const MAX_GATEWAY_BODY_CHARS = 32 * 1024 * 1024
/// How long the opener waits for "accepted" before giving up on the target.
export const GATEWAY_ACCEPT_TIMEOUT_MS = 20_000

export interface GatewayExchange {
  readonly status: number
  readonly body: string
}

/// "before-send": the target provably never started the request (it was
/// refused, or never delivered). "in-flight": it may have run.
export type GatewayChannelPhase = "before-send" | "in-flight"

export class GatewayChannelError extends Error {
  override readonly name = "GatewayChannelError"
  constructor(
    readonly phase: GatewayChannelPhase,
    readonly reason: string,
    /// Set when the target itself closed the channel (e.g. "unsupported":
    /// it runs a version without gateway channels).
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

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

/// Responder refusals that happen before the handler runs.
const REFUSALS: ReadonlySet<string> = new Set(["unsupported", "rejected", "crypto-error"])

/// Whether a channel end proves the request never reached the handler.
const endedBeforeSend = (end: OutgoingChannelEnd, accepted: boolean): boolean => {
  if (accepted) return false
  // Undelivered frames: the request's final frame never reached the target
  // (a later frame could only be a cancel, which this side never sent).
  if (end.kind === "undeliverable") return true
  return end.kind === "peer-closed" && REFUSALS.has(end.reason)
}

const describeEnd = (end: OutgoingChannelEnd): string =>
  end.kind === "peer-closed" ? `closed by the target (${end.reason})` : end.kind

export interface GatewayRequestOptions {
  readonly signal?: AbortSignal
  readonly acceptTimeoutMs?: number
  readonly scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
}

/// Runs one exchange. `open` sends the channel open; if it throws, nothing
/// was sent (before-send). Resolves with
/// the responder's answer; rejects with GatewayChannelError, or with the
/// signal's reason when aborted (the responder is told to cancel).
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
          // An outdated target answers like one that refuses the channel type.
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
      signal?.removeEventListener("abort", onAbort)
      return true
    }
    const fail = (error: unknown, closeReason?: "done" | "protocol-error"): void => {
      if (!settle()) return
      if (closeReason !== undefined) channel.close(closeReason)
      reject(error)
    }
    const onAbort = (): void => fail(signal!.reason, "done")
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
      if (value.kind === "accepted") {
        accepted = true
        cancelAcceptTimeout?.()
        cancelAcceptTimeout = undefined
        return
      }
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

/// Serves gateway channels: buffers the request, runs `handle` with an
/// AbortSignal that fires if the opener cancels or vanishes, and streams the
/// answer back. Handler failures answer 502 so the opener always learns the
/// outcome of a request that ran.
export const gatewayChannelHandler =
  (
    handle: (request: string, signal: AbortSignal) => Promise<GatewayExchange>,
    log: (line: string) => void
  ): ChannelHandler =>
  (channel) => {
    const controller = new AbortController()
    let request = ""
    let started = false
    channel.onClosed = () => controller.abort(new Error("the caller cancelled the request"))
    channel.onData = (value) => {
      if (started) return
      if (isRecord(value) && value.kind === "chunk" && typeof value.data === "string") {
        request += value.data
        if (request.length <= MAX_GATEWAY_BODY_CHARS) return
      } else if (isRecord(value) && value.kind === "end") {
        started = true
        channel.send({ kind: "accepted" })
        void run()
        return
      }
      started = true
      channel.close("rejected")
    }
    const run = async (): Promise<void> => {
      let answer: GatewayExchange
      try {
        answer = await handle(request, controller.signal)
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

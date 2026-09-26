import { request as httpRequest } from "node:http"
import { request as httpsRequest } from "node:https"

/// The direct (LAN/tailnet) path to a peer machine's API: the FleetRoster
/// route `{url, token}` every server replicates. One POST per gateway call,
/// on a fresh connection, reporting precisely whether the request could
/// have reached the peer — the caller falls back to the cloud relay only
/// when it provably did not.

export interface DirectRoute {
  readonly url: string
  readonly token?: string
}

export interface DirectAnswer {
  readonly status: number
  readonly body: string
}

/// "before-send": the request never fully left this machine (connect failed
/// or timed out). "in-flight": it was fully sent; the peer may have run it.
export class DirectPathError extends Error {
  override readonly name = "DirectPathError"
  constructor(
    readonly phase: "before-send" | "in-flight",
    message: string
  ) {
    super(message)
  }
}

export const DIRECT_CONNECT_TIMEOUT_MS = 2500

export interface DirectPostOptions {
  readonly signal?: AbortSignal
  readonly connectTimeoutMs?: number
  readonly scheduleTimeout?: (callback: () => void, delayMs: number) => () => void
}

const defaultSchedule = (callback: () => void, delayMs: number): (() => void) => {
  const timer = setTimeout(callback, delayMs)
  return () => clearTimeout(timer)
}

/// POSTs `body` (JSON) to `path` on the route. Resolves with any HTTP answer;
/// rejects with DirectPathError, or with the signal's reason when aborted.
export const postDirect = (
  route: DirectRoute,
  path: string,
  body: string,
  options: DirectPostOptions = {}
): Promise<DirectAnswer> =>
  new Promise<DirectAnswer>((resolve, reject) => {
    const { signal } = options
    if (signal?.aborted === true) {
      reject(signal.reason)
      return
    }
    const url = new URL(path, route.url)
    const secure = url.protocol === "https:"
    let finished = false
    let settled = false
    /// First outcome wins; later events (e.g. the error a destroy emits
    /// after an abort) are ignored.
    const settle = (outcome: () => void): void => {
      if (settled) return
      settled = true
      cancelConnectTimeout()
      signal?.removeEventListener("abort", onAbort)
      outcome()
    }
    const request = (secure ? httpsRequest : httpRequest)(
      url,
      {
        method: "POST",
        // A pooled socket the peer already closed fails only after the
        // request was written — indistinguishable from a real mid-call loss.
        agent: false,
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
          ...(route.token === undefined ? {} : { authorization: `Bearer ${route.token}` })
        }
      },
      (response) => {
        const chunks: Buffer[] = []
        response.on("data", (chunk: Buffer) => chunks.push(chunk))
        // The connection died mid-answer: the call ran (or is running).
        response.on("error", (cause) => {
          settle(() => reject(new DirectPathError("in-flight", cause.message)))
        })
        response.on("end", () => {
          settle(() =>
            resolve({
              // Always set on a client response.
              status: response.statusCode as number,
              body: Buffer.concat(chunks).toString("utf8")
            })
          )
        })
      }
    )
    const cancelConnectTimeout = (options.scheduleTimeout ?? defaultSchedule)(() => {
      request.destroy(new DirectPathError("before-send", "timed out connecting"))
    }, options.connectTimeoutMs ?? DIRECT_CONNECT_TIMEOUT_MS)
    request.on("socket", (socket) => {
      socket.once(secure ? "secureConnect" : "connect", cancelConnectTimeout)
    })
    // Every byte of the request was handed to the OS: from here on the peer
    // may have received it and started the call.
    request.on("finish", () => {
      finished = true
    })
    request.on("error", (cause) => {
      settle(() =>
        reject(
          cause instanceof DirectPathError
            ? cause
            : new DirectPathError(finished ? "in-flight" : "before-send", cause.message)
        )
      )
    })
    const onAbort = (): void => {
      settle(() => reject(signal!.reason))
      request.destroy()
    }
    signal?.addEventListener("abort", onAbort, { once: true })
    request.end(body)
  })

/// Reachability for machine lists: the tokenless discovery manifest answers
/// quickly on any live Codevisor server.
/// Whether a direct machine answered, and the platform it reports for itself
/// (authoritative over registry copies that can go stale).
export interface DirectProbe {
  readonly online: boolean
  readonly os?: string
}

export const probeDirect = async (route: DirectRoute, timeoutMs = 1500): Promise<DirectProbe> => {
  try {
    const response = await fetch(new URL("/v1/discovery", route.url), {
      signal: AbortSignal.timeout(timeoutMs)
    })
    if (!response.ok) {
      await response.body?.cancel()
      return { online: false }
    }
    const manifest = (await response.json().catch(() => undefined)) as
      | { readonly platform?: unknown }
      | undefined
    return typeof manifest?.platform === "string"
      ? { online: true, os: manifest.platform }
      : { online: true }
  } catch {
    return { online: false }
  }
}

/// The gateway call itself: POST /v1/gateway/invoke on the peer.
export const postGatewayInvoke = (
  route: DirectRoute,
  body: string,
  signal?: AbortSignal
): Promise<DirectAnswer> =>
  postDirect(route, "/v1/gateway/invoke", body, signal === undefined ? {} : { signal })

import { PassThrough } from "node:stream"
import { describe, expect, it } from "vitest"
import { makeNdjsonTransport } from "../stdio-transport.js"
import type { StdioEndpoint } from "../stdio-transport.js"
import { wireCodexClient } from "./client.js"

/// The transport seam is where write-after-exit bugs live: replies to
/// approvals/questions settle on human timescales and routinely outlive the
/// codex process. Before the lifecycle-gated transport, one late reply to a
/// dead stdin was an unhandled stream 'error' — fatal to the WHOLE server
/// process, not just the session. These tests drive exactly those races.

const flush = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

interface FakeChild {
  readonly endpoint: StdioEndpoint
  readonly stdout: PassThrough
  readonly stderr: PassThrough
  readonly stdin: PassThrough
  exit: (error?: Error) => void
  frames: () => Array<Record<string, unknown>>
  killed: () => boolean
}

const makeFakeChild = (): FakeChild => {
  const stdin = new PassThrough()
  const stdout = new PassThrough()
  const stderr = new PassThrough()
  const exitHandlers: Array<(error: Error | undefined) => void> = []
  const written: Array<string> = []
  stdin.on("data", (chunk: Buffer | string) => written.push(chunk.toString()))
  let killed = false
  return {
    endpoint: {
      kill: () => {
        killed = true
      },
      onExit: (handler) => {
        exitHandlers.push(handler)
      },
      pid: 4242,
      stderr,
      stdin,
      stdout
    },
    exit: (error) => {
      for (const handler of exitHandlers) handler(error)
    },
    frames: () =>
      written
        .join("")
        .split("\n")
        .filter((line) => line.trim().length > 0)
        .map((line) => JSON.parse(line) as Record<string, unknown>),
    killed: () => killed,
    stderr,
    stdin,
    stdout
  }
}

const makeClient = (child: FakeChild) =>
  wireCodexClient(
    makeNdjsonTransport(child.endpoint, { exitMessage: "codex app-server exited" })
  )

describe("codex client over the ndjson transport", () => {
  it("round-trips an outbound request", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const reply = client.request<{ ok: boolean }>("thread/list", { cursor: null })
    await flush()
    expect(child.frames()).toEqual([{ id: 1, method: "thread/list", params: { cursor: null } }])
    child.stdout.write(`${JSON.stringify({ id: 1, result: { ok: true } })}\n`)
    await expect(reply).resolves.toEqual({ ok: true })
  })

  it("rejects an outbound request on a JSON-RPC error", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const reply = client.request("thread/list")
    await flush()
    child.stdout.write(`${JSON.stringify({ error: { message: "nope" }, id: 1 })}\n`)
    await expect(reply).rejects.toThrow("nope")
  })

  it("dispatches notifications and reassembles frames split across chunks", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const seen: Array<{ method: string; params: unknown }> = []
    client.onNotification((method, params) => seen.push({ method, params }))
    const frame = `${JSON.stringify({ method: "item/started", params: { itemId: "i1" } })}\n`
    child.stdout.write(frame.slice(0, 10))
    await flush()
    child.stdout.write(frame.slice(10))
    await flush()
    expect(seen).toEqual([{ method: "item/started", params: { itemId: "i1" } }])
  })

  it("answers a server→client request through the handler", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    client.onRequest((method) => Promise.resolve({ answered: method }))
    child.stdout.write(
      `${JSON.stringify({ id: 9, method: "item/tool/requestUserInput", params: {} })}\n`
    )
    await flush()
    await flush()
    expect(child.frames()).toEqual([{ id: 9, result: { answered: "item/tool/requestUserInput" } }])
  })

  it("replies -32601 when no request handler is registered", async () => {
    const child = makeFakeChild()
    makeClient(child)
    child.stdout.write(`${JSON.stringify({ id: 3, method: "whatever" })}\n`)
    await flush()
    expect(child.frames()).toEqual([
      { error: { code: -32601, message: "No handler for whatever" }, id: 3 }
    ])
  })

  it("drops a reply that settles after the process died (the crash regression)", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    let answer: ((value: unknown) => void) | undefined
    client.onRequest(
      () =>
        new Promise((resolve) => {
          answer = resolve
        })
    )
    child.stdout.write(
      `${JSON.stringify({ id: 5, method: "item/tool/requestUserInput", params: {} })}\n`
    )
    await flush()
    child.exit()
    // The human's answer arrives after codex is gone: it must be discarded,
    // not written into the dead pipe (which was an unhandled stream error
    // fatal to the entire server).
    answer?.({ answers: {} })
    await flush()
    await flush()
    expect(child.frames()).toEqual([])
  })

  it("drops a reply that settles after deliberate close, with stdin already ended", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    let answer: ((value: unknown) => void) | undefined
    client.onRequest(
      () =>
        new Promise((resolve) => {
          answer = resolve
        })
    )
    child.stdout.write(
      `${JSON.stringify({ id: 6, method: "item/commandExecution/requestApproval", params: {} })}\n`
    )
    await flush()
    client.close()
    expect(child.killed()).toBe(true)
    // stdin.end() has run — an unguarded write here is exactly the historic
    // write-after-end crash.
    answer?.({ decision: "accept" })
    await flush()
    await flush()
    expect(child.frames()).toEqual([])
  })

  it("aborts in-flight server→client requests when the process dies", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const signals: Array<AbortSignal> = []
    client.onRequest((_method, _params, signal) => {
      signals.push(signal)
      return new Promise(() => undefined)
    })
    const closeErrors: Array<Error> = []
    client.onClose((error) => closeErrors.push(error))
    child.stdout.write(
      `${JSON.stringify({ id: 7, method: "item/tool/requestUserInput", params: {} })}\n`
    )
    await flush()
    expect(signals[0]?.aborted).toBe(false)
    child.stderr.write("codex blew up")
    await flush()
    child.exit()
    expect(signals[0]?.aborted).toBe(true)
    expect(closeErrors.map((error) => error.message)).toEqual(["codex blew up"])
  })

  it("aborts in-flight server→client requests on deliberate close without reporting a crash", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const signals: Array<AbortSignal> = []
    client.onRequest((_method, _params, signal) => {
      signals.push(signal)
      return new Promise(() => undefined)
    })
    const closeErrors: Array<Error> = []
    client.onClose((error) => closeErrors.push(error))
    child.stdout.write(
      `${JSON.stringify({ id: 8, method: "item/tool/requestUserInput", params: {} })}\n`
    )
    await flush()
    client.close()
    expect(signals[0]?.aborted).toBe(true)
    // Routine teardown must not masquerade as a crash.
    expect(closeErrors).toEqual([])
  })

  it("rejects outstanding outbound requests with the stderr tail on exit", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const reply = client.request("turn/start")
    await flush()
    child.stderr.write("panic: everything is on fire")
    await flush()
    child.exit()
    await expect(reply).rejects.toThrow("panic: everything is on fire")
  })

  it("falls back to the exit message when the process dies silently", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const reply = client.request("turn/start")
    await flush()
    child.exit()
    await expect(reply).rejects.toThrow("codex app-server exited")
  })

  it("contains a stdin pipe error as a session failure instead of a process crash", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const closeErrors: Array<Error> = []
    client.onClose((error) => closeErrors.push(error))
    child.stdin.destroy(new Error("EPIPE"))
    await flush()
    expect(closeErrors.map((error) => error.message)).toEqual(["EPIPE"])
    // Later traffic is dropped, not thrown.
    client.notify("noop")
    await expect(client.request("turn/start")).rejects.toThrow(
      "codex app-server connection is closed"
    )
  })

  it("rejects new requests after deliberate close and fires close handlers only once", async () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    const closeErrors: Array<Error> = []
    client.onClose((error) => closeErrors.push(error))
    const reply = client.request("turn/start")
    await flush()
    client.close()
    await expect(reply).rejects.toThrow("codex client closed")
    // The kill-induced exit after close is expected teardown, not a crash.
    child.exit()
    expect(closeErrors).toEqual([])
    await expect(client.request("thread/list")).rejects.toThrow(
      "codex app-server connection is closed"
    )
  })

  it("exposes the child pid", () => {
    const child = makeFakeChild()
    const client = makeClient(child)
    expect(client.pid).toBe(4242)
  })
})

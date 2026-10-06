import { spawn } from "node:child_process"
import { randomBytes } from "node:crypto"
import type { EventEmitter } from "node:events"

/// One OpenCode 2 server process: `opencode serve --stdio`, which prints its
/// URL as the first stdout line and runs until its stdin closes (the
/// ownership lease), so a crashed Codevisor server can't orphan it. Requests
/// authenticate with the password Codevisor generated for it.

export interface OpenCodeChild extends EventEmitter {
  readonly stdout: EventEmitter
  readonly stderr: EventEmitter
  readonly stdin: { end: () => void }
  readonly exitCode: number | null
  readonly kill: (signal?: NodeJS.Signals) => boolean
}

export interface OpenCodeServerOptions {
  readonly command: string
  readonly env: NodeJS.ProcessEnv
  readonly cwd?: string
  readonly spawnChild?: (
    command: string,
    args: ReadonlyArray<string>,
    options: {
      readonly cwd?: string
      readonly env: NodeJS.ProcessEnv
    }
  ) => OpenCodeChild
  readonly fetch?: typeof fetch
  /// Resolves after `ms`; injected so startup and shutdown deadlines are testable.
  readonly wait?: (ms: number) => Promise<void>
}

export interface OpenCodeServer {
  readonly url: string
  /// JSON request against the server's API. `location` scopes
  /// location-bound endpoints (integrations, models) to a directory.
  readonly request: <A>(
    path: string,
    init?: { readonly method?: string; readonly body?: unknown; readonly location?: string }
  ) => Promise<A>
  /// Ends the lease, then kills the process if it hasn't exited shortly after.
  readonly stop: () => Promise<void>
}

export class OpenCodeServerError extends Error {
  constructor(
    message: string,
    readonly status?: number
  ) {
    super(message)
  }
}

const STARTUP_BUDGET_MS = 30_000
const READY_POLL_MS = 250
const STOP_GRACE_MS = 1_000
const OUTPUT_LIMIT = 16_384

const spawnOpenCode: NonNullable<OpenCodeServerOptions["spawnChild"]> = (command, args, options) =>
  spawn(command, [...args], { ...options, stdio: ["pipe", "pipe", "pipe"] })

const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms).unref())

export const startOpenCodeServer = async (
  options: OpenCodeServerOptions
): Promise<OpenCodeServer> => {
  const wait = options.wait ?? delay
  const request = options.fetch ?? fetch
  const password = randomBytes(24).toString("base64url")
  const child = (options.spawnChild ?? spawnOpenCode)(
    options.command,
    ["serve", "--stdio", "--port", "0"],
    {
      ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
      env: { ...options.env, OPENCODE_PASSWORD: password }
    }
  )
  let stderr = ""
  child.stderr.on("data", (chunk: Buffer | string) => {
    if (stderr.length < OUTPUT_LIMIT) stderr += String(chunk)
  })
  // A spawn failure surfaces as an error event; keep it from crashing the
  // server once startup has settled.
  child.on("error", () => undefined)
  const exited = new Promise<number | null>((resolve) => {
    if (child.exitCode !== null) resolve(child.exitCode)
    else child.once("exit", (code: number | null) => resolve(code))
  })
  const exitFailure = (code: number | null) =>
    new OpenCodeServerError(
      stderr.trim() || `OpenCode server exited before it started (status ${code ?? "unknown"})`
    )

  let stopping: Promise<void> | undefined
  const stop = () => {
    stopping ??= (async () => {
      if (child.exitCode !== null) return
      child.stdin.end()
      const graceful = await Promise.race([
        exited.then(() => true),
        wait(STOP_GRACE_MS).then(() => false)
      ])
      if (!graceful && child.exitCode === null) child.kill("SIGKILL")
    })()
    return stopping
  }

  const url = await new Promise<string>((resolve, reject) => {
    let output = ""
    const onData = (chunk: Buffer | string) => {
      output += String(chunk)
      const newline = output.indexOf("\n")
      if (newline === -1) {
        if (output.length > OUTPUT_LIMIT)
          fail(new OpenCodeServerError("OpenCode server printed no address"))
        return
      }
      try {
        const parsed = JSON.parse(output.slice(0, newline)) as { url?: unknown }
        if (typeof parsed.url !== "string") throw new Error("missing url")
        settle()
        resolve(parsed.url.replace(/\/$/, ""))
      } catch {
        fail(
          new OpenCodeServerError(
            `OpenCode server printed an unexpected address: ${output.slice(0, newline)}`
          )
        )
      }
    }
    const onError = (cause: Error) => fail(new OpenCodeServerError(cause.message))
    const onExit = (code: number | null) => fail(exitFailure(code))
    const settle = () => {
      child.stdout.off("data", onData)
      child.off("error", onError)
      child.off("exit", onExit)
    }
    const fail = (cause: Error) => {
      settle()
      void stop()
      reject(cause)
    }
    child.stdout.on("data", onData)
    child.once("error", onError)
    child.once("exit", onExit)
  })

  const authorization = `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`
  const call = async <A>(
    path: string,
    init: { readonly method?: string; readonly body?: unknown; readonly location?: string } = {}
  ): Promise<A> => {
    const target = new URL(`${url}${path}`)
    if (init.location !== undefined) target.searchParams.set("location[directory]", init.location)
    const response = await request(target, {
      method: init.method ?? (init.body === undefined ? "GET" : "POST"),
      headers: {
        authorization,
        ...(init.body === undefined ? {} : { "content-type": "application/json" })
      },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) })
    })
    const text = await response.text()
    if (!response.ok) {
      let message = text
      try {
        message = (JSON.parse(text) as { message?: string }).message ?? text
      } catch {
        // Keep the body when OpenCode didn't answer with JSON.
      }
      throw new OpenCodeServerError(
        message.trim() || `OpenCode request failed (${response.status})`,
        response.status
      )
    }
    return (text.length === 0 ? undefined : JSON.parse(text)) as A
  }

  // The address is printed before the app finishes booting; /api/info
  // answers 503 until then.
  for (let waited = 0; ; waited += READY_POLL_MS) {
    if (child.exitCode !== null) throw exitFailure(child.exitCode)
    try {
      await call("/api/info")
      break
    } catch (cause) {
      if (!(cause instanceof OpenCodeServerError) || cause.status !== 503) {
        await stop()
        throw cause
      }
    }
    if (waited >= STARTUP_BUDGET_MS) {
      await stop()
      throw new OpenCodeServerError(
        `OpenCode server did not start within ${STARTUP_BUDGET_MS / 1000} seconds`
      )
    }
    await wait(READY_POLL_MS)
  }
  return { url, request: call, stop }
}

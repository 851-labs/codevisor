import type {
  TerminalClientFrame,
  TerminalCreateRequest,
  TerminalCreateResponse,
  TerminalServerFrame
} from "@herdman/api"
import { randomUUID } from "node:crypto"
import { Context, Effect, Layer, Schema } from "effect"

export class TerminalError extends Schema.TaggedErrorClass<TerminalError>()("TerminalError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface TerminalProcess {
  readonly write: (data: string) => void
  readonly resize: (cols: number, rows: number) => void
  readonly kill: () => void
}

export interface TerminalSpawnRequest extends TerminalCreateRequest {
  readonly shell: string
  readonly env: NodeJS.ProcessEnv
}

export interface TerminalHandlers {
  readonly onOutput: (data: string) => void
  readonly onExit: (exitCode: number | undefined) => void
}

export interface TerminalSpawner {
  readonly spawn: (
    request: TerminalSpawnRequest,
    handlers: TerminalHandlers
  ) => Effect.Effect<TerminalProcess, TerminalError>
}

export interface TerminalManagerConfig {
  readonly defaultShell?: string
  readonly env?: NodeJS.ProcessEnv
  readonly spawner?: TerminalSpawner
}

/// Caller-facing side of an externally-managed terminal: the caller owns the
/// process and pumps its output/exit through this handle; input, resize, and
/// kill flow back through the `TerminalProcess` supplied at registration.
export interface ExternalTerminalHandle {
  readonly terminalId: string
  readonly response: TerminalCreateResponse
  readonly output: (data: string) => void
  readonly exit: (exitCode?: number) => void
  /// Removes the terminal entirely (frames included) — for terminals that
  /// were never surfaced to a client, so nothing lingers after a short-lived
  /// process ends. Safe to call after `exit`.
  readonly remove: () => void
}

export interface ExternalTerminalConfig {
  readonly sessionId: string
  /// Pipe-fed processes emit bare "\n" line endings; a real terminal renderer
  /// needs "\r\n". Enabled for mirrors/wrappers that read pipes, not PTYs.
  readonly normalizeNewlines?: boolean
}

/// External terminals can outlive any single client and stream indefinitely
/// (dev servers); cap the replay buffer so memory stays bounded. Clients that
/// reconnect past the trim point lose the oldest scrollback only.
const EXTERNAL_TERMINAL_MAX_FRAMES = 20_000

export interface TerminalManagerService {
  readonly createTerminal: (
    request: TerminalCreateRequest,
    envOverrides?: NodeJS.ProcessEnv
  ) => Effect.Effect<TerminalCreateResponse, TerminalError>
  readonly connectTerminal: (
    terminalId: string,
    lastOutputSeq: number,
    sink: (frame: TerminalServerFrame) => void
  ) => Effect.Effect<() => void, TerminalError>
  readonly handleClientFrame: (
    terminalId: string,
    frame: TerminalClientFrame
  ) => Effect.Effect<void, TerminalError>
  readonly terminalFrames: (
    terminalId: string,
    since?: number
  ) => Effect.Effect<ReadonlyArray<TerminalServerFrame>, TerminalError>
  readonly closeTerminal: (terminalId: string) => Effect.Effect<void, TerminalError>
  /// Kills the live terminal for a session (if any), so the next createTerminal
  /// for that session spawns a fresh shell. Returns whether one was closed.
  readonly closeTerminalForSession: (sessionId: string) => Effect.Effect<boolean, TerminalError>
  /// Kills and removes every terminal whose session key starts with `prefix`
  /// (scrollback included). Used when a chat session is archived: its
  /// background-task terminals (`<agentSessionId>:bg:...`) must not keep
  /// processes running. Returns how many terminals were removed.
  readonly closeTerminalsForSessionPrefix: (prefix: string) => Effect.Effect<number, TerminalError>
  /// Registers a terminal whose process the CALLER owns (an agent's background
  /// shell, a mirrored remote process). The manager never spawns or respawns
  /// it: clients attach with `attachOnly` createTerminal requests, and the
  /// terminal remains attachable after exit so its scrollback stays readable.
  readonly registerExternalTerminal: (
    config: ExternalTerminalConfig,
    process: TerminalProcess
  ) => ExternalTerminalHandle
}

export class TerminalManager extends Context.Service<TerminalManager, TerminalManagerService>()(
  "@herdman/terminal/TerminalManager"
) {
  static readonly layer = (config: TerminalManagerConfig = {}): Layer.Layer<TerminalManager> =>
    Layer.succeed(TerminalManager, TerminalManager.of(makeTerminalManager(config)))
}

interface RunningTerminal {
  readonly terminalId: string
  readonly sessionId: string
  readonly process: TerminalProcess
  readonly sinks: Set<(frame: TerminalServerFrame) => void>
  readonly frames: Array<TerminalServerFrame>
  readonly clientSeqs: Map<string, number>
  nextOutputSeq: number
  closed: boolean
  /// Externally-managed terminals are never (re)spawned by the manager and
  /// stay attachable after exit (scrollback survives until removed).
  readonly external: boolean
}

type TerminalFramePayload =
  | { readonly type: "output"; readonly data: string }
  | { readonly type: "exit"; readonly exitCode?: number }

export const makeTerminalManager = (config: TerminalManagerConfig = {}): TerminalManagerService => {
  const terminals = new Map<string, RunningTerminal>()
  const terminalsBySession = new Map<string, string>()
  /* v8 ignore next -- real node-pty spawning is covered by packaging smoke tests. */
  const spawner = config.spawner ?? nodePtySpawner
  const env = config.env ?? process.env
  /* v8 ignore next -- the final fallback depends on host SHELL environment state. */
  const defaultShell = config.defaultShell ?? process.env.SHELL ?? "/bin/sh"

  const pushFrame = (
    terminal: RunningTerminal,
    frame: TerminalFramePayload
  ): TerminalServerFrame => {
    const sequenced = sequenceFrame(terminal.nextOutputSeq, frame)
    terminal.nextOutputSeq += 1
    terminal.frames.push(sequenced)
    if (terminal.external && terminal.frames.length > EXTERNAL_TERMINAL_MAX_FRAMES) {
      terminal.frames.splice(0, terminal.frames.length - EXTERNAL_TERMINAL_MAX_FRAMES)
    }
    for (const sink of terminal.sinks) {
      sink(sequenced)
    }
    return sequenced
  }

  const getTerminal = (terminalId: string, operation: string): RunningTerminal => {
    const terminal = terminals.get(terminalId)
    if (terminal === undefined) {
      throw new TerminalError({ operation, message: `Terminal not found: ${terminalId}` })
    }
    return terminal
  }

  const clearSessionMapping = (terminal: RunningTerminal): void => {
    if (terminalsBySession.get(terminal.sessionId) === terminal.terminalId) {
      terminalsBySession.delete(terminal.sessionId)
    }
  }

  return {
    createTerminal: (request, envOverrides) =>
      Effect.gen(function* () {
        if (request.cols < 1 || request.rows < 1) {
          return yield* Effect.fail(
            new TerminalError({
              operation: "createTerminal",
              message: "Terminal dimensions must be positive"
            })
          )
        }

        const existingTerminalId = terminalsBySession.get(request.sessionId)
        if (existingTerminalId !== undefined) {
          const existing = terminals.get(existingTerminalId)!
          // External terminals stay attachable after exit: the process is
          // agent-owned and will not be respawned, but the scrollback (and
          // the exit frame) must still replay to a connecting client.
          if (!existing.closed || existing.external) {
            return terminalResponse(existing)
          }
        }
        if (request.attachOnly === true) {
          return yield* Effect.fail(
            new TerminalError({
              operation: "createTerminal",
              message: `No terminal registered for session: ${request.sessionId}`
            })
          )
        }

        const terminalId = randomUUID()
        const spawnRequest: TerminalSpawnRequest = {
          ...request,
          shell: request.shell ?? defaultShell,
          env: { ...env, ...envOverrides }
        }
        const pendingFrames: Array<TerminalFramePayload> = []
        let runningTerminal: RunningTerminal | undefined
        let exitedBeforeRegistration = false
        const publishFrame = (frame: TerminalFramePayload): void => {
          if (runningTerminal === undefined) {
            pendingFrames.push(frame)
          } else {
            pushFrame(runningTerminal, frame)
          }
        }
        const process = yield* spawner.spawn(spawnRequest, {
          onOutput: (data) => publishFrame({ type: "output", data }),
          onExit: (exitCode) => {
            if (runningTerminal === undefined) {
              exitedBeforeRegistration = true
            } else {
              runningTerminal.closed = true
            }
            publishFrame(exitCode === undefined ? { type: "exit" } : { type: "exit", exitCode })
          }
        })
        const terminal: RunningTerminal = {
          terminalId,
          sessionId: request.sessionId,
          process,
          sinks: new Set(),
          frames: [],
          clientSeqs: new Map(),
          nextOutputSeq: 1,
          closed: exitedBeforeRegistration,
          external: false
        }
        runningTerminal = terminal
        for (const frame of pendingFrames) {
          pushFrame(terminal, frame)
        }
        terminals.set(terminalId, terminal)
        if (!terminal.closed) {
          terminalsBySession.set(request.sessionId, terminalId)
        }
        return terminalResponse(terminal)
      }),
    connectTerminal: (terminalId, lastOutputSeq, sink) =>
      terminalAttempt("connectTerminal", () => {
        const terminal = getTerminal(terminalId, "connectTerminal")
        terminal.sinks.add(sink)
        for (const frame of terminal.frames.filter((candidate) => candidate.seq > lastOutputSeq)) {
          sink(frame)
        }
        return () => {
          terminal.sinks.delete(sink)
        }
      }),
    handleClientFrame: (terminalId, frame) =>
      terminalAttempt("handleClientFrame", () => {
        const terminal = getTerminal(terminalId, "handleClientFrame")
        if (terminal.closed) {
          // Clients legitimately attach to exited external terminals to read
          // scrollback; their input/resize frames are meaningless, not errors.
          if (terminal.external) {
            return
          }
          throw new Error(`Terminal already closed: ${terminalId}`)
        }
        if (isDuplicateClientFrame(terminal, frame.clientId, frame.clientSeq)) {
          return
        }
        terminal.clientSeqs.set(frame.clientId, frame.clientSeq)

        switch (frame.type) {
          case "input": {
            terminal.process.write(frame.data)
            break
          }
          case "resize": {
            terminal.process.resize(frame.cols, frame.rows)
            break
          }
          case "close": {
            terminal.closed = true
            terminal.process.kill()
            clearSessionMapping(terminal)
            break
          }
        }
      }),
    terminalFrames: (terminalId, since = 0) =>
      terminalAttempt("terminalFrames", () =>
        getTerminal(terminalId, "terminalFrames").frames.filter((frame) => frame.seq > since)
      ),
    closeTerminal: (terminalId) =>
      terminalAttempt("closeTerminal", () => {
        const terminal = getTerminal(terminalId, "closeTerminal")
        terminal.closed = true
        terminal.process.kill()
        terminals.delete(terminalId)
        clearSessionMapping(terminal)
      }),
    closeTerminalForSession: (sessionId) =>
      terminalAttempt("closeTerminalForSession", () => {
        const terminalId = terminalsBySession.get(sessionId)
        if (terminalId === undefined) {
          return false
        }
        // The session mapping only ever points at a registered terminal
        // (closeTerminal and close frames clear the mapping when removing).
        const terminal = getTerminal(terminalId, "closeTerminalForSession")
        if (terminal.closed) {
          // The pty already exited on its own; just drop the stale mapping.
          // Exited external terminals are kept attachable for scrollback, so
          // an explicit session close is when they finally get removed.
          if (terminal.external) {
            terminals.delete(terminalId)
          }
          terminalsBySession.delete(sessionId)
          return false
        }
        terminal.closed = true
        terminal.process.kill()
        terminals.delete(terminalId)
        clearSessionMapping(terminal)
        return true
      }),
    closeTerminalsForSessionPrefix: (prefix) =>
      terminalAttempt("closeTerminalsForSessionPrefix", () => {
        let closed = 0
        for (const [sessionId, terminalId] of [...terminalsBySession]) {
          if (!sessionId.startsWith(prefix)) continue
          const terminal = terminals.get(terminalId)
          /* v8 ignore next -- defensive: every code path that removes a terminal also clears its session mapping. */
          if (terminal === undefined) continue
          if (!terminal.closed) {
            terminal.closed = true
            terminal.process.kill()
          }
          terminals.delete(terminalId)
          terminalsBySession.delete(sessionId)
          closed += 1
        }
        return closed
      }),
    registerExternalTerminal: (config, process) => {
      const terminalId = randomUUID()
      const terminal: RunningTerminal = {
        terminalId,
        sessionId: config.sessionId,
        process,
        sinks: new Set(),
        frames: [],
        clientSeqs: new Map(),
        nextOutputSeq: 1,
        closed: false,
        external: true
      }
      // A re-registration under the same key replaces the previous terminal
      // (e.g. an agent restarting its dev server): drop the stale one so the
      // mapping never points at output from a dead process.
      const previousId = terminalsBySession.get(config.sessionId)
      if (previousId !== undefined) {
        terminals.delete(previousId)
      }
      terminals.set(terminalId, terminal)
      terminalsBySession.set(config.sessionId, terminalId)
      const normalize = config.normalizeNewlines === true
      return {
        terminalId,
        response: terminalResponse(terminal),
        output: (data) => {
          pushFrame(terminal, {
            type: "output",
            data: normalize ? data.replace(/(?<!\r)\n/g, "\r\n") : data
          })
        },
        exit: (exitCode) => {
          if (terminal.closed) return
          terminal.closed = true
          pushFrame(
            terminal,
            exitCode === undefined ? { type: "exit" } : { type: "exit", exitCode }
          )
        },
        remove: () => {
          terminals.delete(terminalId)
          clearSessionMapping(terminal)
        }
      }
    }
  }
}

/* v8 ignore start -- native adapter is exercised by packaging smoke tests, not unit tests. */
export const nodePtySpawner: TerminalSpawner = {
  spawn: (request, handlers) =>
    Effect.tryPromise({
      try: async () => {
        const pty = await import("node-pty")
        const child = pty.spawn(request.shell, [...(request.args ?? [])], {
          cols: request.cols,
          cwd: request.cwd,
          env: request.env,
          name: "xterm-256color",
          rows: request.rows
        })
        child.onData(handlers.onOutput)
        child.onExit(({ exitCode }) => handlers.onExit(exitCode))
        return {
          write: (data) => child.write(data),
          resize: (cols, rows) => child.resize(cols, rows),
          kill: () => child.kill()
        }
      },
      catch: (cause) =>
        new TerminalError({
          operation: "spawn",
          message: cause instanceof Error ? cause.message : String(cause)
        })
    })
}
/* v8 ignore stop */

const terminalAttempt = <A>(operation: string, run: () => A): Effect.Effect<A, TerminalError> =>
  Effect.try({
    try: run,
    catch: (cause) =>
      cause instanceof TerminalError
        ? cause
        : new TerminalError({
            operation,
            message: cause instanceof Error ? cause.message : String(cause)
          })
  })

const terminalResponse = (terminal: RunningTerminal): TerminalCreateResponse => ({
  terminalId: terminal.terminalId,
  websocketPath: `/v1/terminals/${terminal.terminalId}/socket`,
  nextOutputSeq: terminal.nextOutputSeq
})

const sequenceFrame = (seq: number, frame: TerminalFramePayload): TerminalServerFrame => {
  switch (frame.type) {
    case "output": {
      return { type: "output", seq, data: frame.data }
    }
    case "exit": {
      return frame.exitCode === undefined
        ? { type: "exit", seq }
        : { type: "exit", seq, exitCode: frame.exitCode }
    }
  }
}

const isDuplicateClientFrame = (
  terminal: RunningTerminal,
  clientId: string,
  clientSeq: number
): boolean => {
  const lastSeq = terminal.clientSeqs.get(clientId)
  return lastSeq !== undefined && clientSeq <= lastSeq
}

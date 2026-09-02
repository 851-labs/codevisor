import type { TerminalServerFrame } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { Context, Effect, Layer } from "effect"

import {
  EXTERNAL_TERMINAL_MAX_FRAMES,
  isDuplicateClientFrame,
  noopProcess,
  sequenceFrame,
  terminalAttempt,
  terminalResponse,
  type RunningTerminal,
  type TerminalFramePayload
} from "./frames.js"
import { nodePtySpawner } from "./node-pty-spawner.js"
import {
  BUNDLED_GHOSTTY_TERMINFO_DIRECTORY,
  GHOSTTY_TERM,
  resolveDefaultShell,
  resolveTerminalName
} from "./shell.js"
import type {
  TerminalManagerConfig,
  TerminalManagerService,
  TerminalSpawnRequest
} from "./types.js"
import { TerminalError } from "./types.js"

export class TerminalManager extends Context.Service<TerminalManager, TerminalManagerService>()(
  "@codevisor/terminal/TerminalManager"
) {
  static readonly layer = (config: TerminalManagerConfig = {}): Layer.Layer<TerminalManager> =>
    Layer.succeed(TerminalManager, TerminalManager.of(makeTerminalManager(config)))
}

export const makeTerminalManager = (config: TerminalManagerConfig = {}): TerminalManagerService => {
  const terminals = new Map<string, RunningTerminal>()
  const terminalsBySession = new Map<string, string>()
  /* v8 ignore next -- real node-pty spawning is covered by packaging smoke tests. */
  const spawner = config.spawner ?? nodePtySpawner
  const env = config.env ?? process.env
  const terminfoDirectory = config.terminfoDirectory ?? BUNDLED_GHOSTTY_TERMINFO_DIRECTORY
  const defaultShell = resolveDefaultShell(config, env)
  const terminalName = resolveTerminalName(config.platform ?? process.platform)

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
        const terminalEnvironment: NodeJS.ProcessEnv = {
          ...env,
          ...envOverrides,
          COLORTERM: "truecolor",
          TERM: terminalName,
          TERM_PROGRAM: "ghostty"
        }
        if (terminalName === GHOSTTY_TERM) {
          terminalEnvironment.TERMINFO = terminfoDirectory
        } else {
          // An inherited Ghostty-only TERMINFO masks the host's standard
          // xterm-256color database for shells such as Zsh.
          delete terminalEnvironment.TERMINFO
        }
        const spawnRequest: TerminalSpawnRequest = {
          ...request,
          shell: request.shell ?? defaultShell,
          // Match Ghostty's launch environment on macOS. Linux uses the
          // broadly recognized xterm-256color name so stock distro profiles
          // enable colors without requiring Ghostty-specific TERM handling.
          env: terminalEnvironment
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
    snapshotTerminals: () => ({
      version: 1,
      terminals: [...terminals.values()].map((terminal) => ({
        terminalId: terminal.terminalId,
        sessionId: terminal.sessionId,
        // Regular terminals have no in-memory cap (they live and die with a
        // session), so bound what we persist to the external-terminal cap.
        frames: terminal.frames.slice(-EXTERNAL_TERMINAL_MAX_FRAMES),
        nextOutputSeq: terminal.nextOutputSeq,
        closed: terminal.closed,
        external: terminal.external
      }))
    }),
    restoreTerminals: (snapshot) => {
      for (const entry of snapshot.terminals) {
        if (terminals.has(entry.terminalId)) continue
        const terminal: RunningTerminal = {
          terminalId: entry.terminalId,
          sessionId: entry.sessionId,
          process: noopProcess,
          sinks: new Set(),
          frames: [...entry.frames],
          // Input dedup state is irrelevant to a closed, process-less
          // terminal: external ones ignore input, regular ones refuse it.
          clientSeqs: new Map(),
          nextOutputSeq: entry.nextOutputSeq,
          closed: true,
          external: entry.external
        }
        // The process died with the previous server; terminals that were
        // still live at snapshot time replay a synthetic exit so attached
        // clients learn the process is gone rather than waiting on it.
        if (!entry.closed) {
          terminal.frames.push(sequenceFrame(terminal.nextOutputSeq, { type: "exit" }))
          terminal.nextOutputSeq += 1
        }
        terminals.set(entry.terminalId, terminal)
        // Only external terminals reclaim their session key: their contract is
        // "attachable after exit". A restored session shell must not claim it,
        // or createTerminal would hand back dead scrollback instead of
        // spawning the fresh shell the client expects.
        if (entry.external && !terminalsBySession.has(entry.sessionId)) {
          terminalsBySession.set(entry.sessionId, entry.terminalId)
        }
      }
    },
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

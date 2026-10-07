import { randomUUID } from "node:crypto"

import { Context, Effect, Layer } from "effect"

import {
  isDuplicateClientFrame,
  noopProcess,
  sequenceFrame,
  terminalAttempt,
  terminalPromise,
  terminalResponse,
  type RunningTerminal,
  type SequencedFrame,
  type TerminalFramePayload
} from "./frames.js"
import { nodePtySpawner } from "./node-pty-spawner.js"
import { ReplayBuffer } from "./replay-buffer.js"
import { SizeArbiter, type TerminalSize } from "./size-arbiter.js"
import { makeTerminalLaunch } from "./terminal-launch.js"
import { createTerminalScreen, replayCovers, resyncFrames } from "./terminal-screen.js"
import { RESTORED_TERMINAL_SIZE, restoreEntry, snapshotEntry } from "./terminal-snapshot.js"
import { makeTerminalTitles } from "./terminal-titles.js"
import type { TerminalManagerConfig, TerminalManagerService } from "./types.js"
import { TerminalError } from "./types.js"
import { createVtTerminal } from "./vt/ghostty-vt.js"

export class TerminalManager extends Context.Service<TerminalManager, TerminalManagerService>()(
  "@codevisor/terminal/TerminalManager"
) {
  static readonly layer = (config: TerminalManagerConfig = {}): Layer.Layer<TerminalManager> =>
    Layer.succeed(TerminalManager, TerminalManager.of(makeTerminalManager(config)))
}

/// Screen size for pipe-fed external processes, which have no PTY size of
/// their own until a client resizes the terminal.
const UNKNOWN_TERMINAL_SIZE = RESTORED_TERMINAL_SIZE
const decoder = new TextDecoder()

const sizeFrame = (size: TerminalSize) =>
  ({ type: "size", seq: 0, cols: size.cols, rows: size.rows }) as const

const applySize = (terminal: RunningTerminal, size: TerminalSize | undefined): void => {
  if (size === undefined) return
  terminal.process.resize(size.cols, size.rows)
  terminal.screen.resize(size.cols, size.rows)
  // Every client learns the PTY's size, so watchers can fit its grid.
  for (const sink of terminal.sinks) sink(sizeFrame(size))
}

/// ⌘K for every client at once, deciding as Ghostty does locally. At the
/// shell's prompt: clear the screen and scrollback everywhere (the server's
/// screen copy included), then hand the shell Ctrl-L so it redraws its prompt
/// and whatever was typed. With a program in the foreground, only scrollback
/// goes: the screen is the program's to draw.
const CLEAR_SCREEN_AND_SCROLLBACK = "\u001b[H\u001b[2J\u001b[3J"
const CLEAR_SCROLLBACK = "\u001b[3J"

export const makeTerminalManager = (config: TerminalManagerConfig = {}): TerminalManagerService => {
  const terminals = new Map<string, RunningTerminal>()
  const terminalsBySession = new Map<string, string>()
  const stopping = new Map<string, Promise<void>>()
  const titles = makeTerminalTitles()
  let revision = 0

  /* v8 ignore next -- real node-pty spawning is covered by packaging smoke tests. */
  const spawner = config.spawner ?? nodePtySpawner
  const prepareSpawn = makeTerminalLaunch(config)

  const pushFrame = (terminal: RunningTerminal, frame: TerminalFramePayload): SequencedFrame => {
    const sequenced = sequenceFrame(terminal.nextOutputSeq, frame)
    terminal.nextOutputSeq += 1
    revision += 1
    terminal.frames.push(sequenced)
    if (sequenced.type === "output") {
      if (!terminal.removed) {
        terminal.screen.write(sequenced.data)
        titles.observe(terminal, sequenced.data)
      }
    } else {
      terminal.exitFrame = sequenced
      titles.end(terminal)
    }
    for (const sink of terminal.sinks) {
      sink(sequenced)
    }
    return sequenced
  }

  const clearTerminal = (terminal: RunningTerminal): void => {
    const atPrompt = terminal.process.isShellInForeground?.() === true
    pushFrame(terminal, {
      type: "output",
      data: atPrompt ? CLEAR_SCREEN_AND_SCROLLBACK : CLEAR_SCROLLBACK
    })
    if (atPrompt) terminal.process.write("\f")
  }

  const getTerminal = (terminalId: string, operation: string): RunningTerminal => {
    const terminal = terminals.get(terminalId)
    if (terminal === undefined) {
      throw new TerminalError({ operation, message: `Terminal not found: ${terminalId}` })
    }
    return terminal
  }

  /// Removes a terminal from the manager and releases its screen state.
  const dropTerminal = (terminal: RunningTerminal): void => {
    if (terminals.get(terminal.terminalId) === terminal) terminals.delete(terminal.terminalId)
    terminal.removed = true
    titles.end(terminal)
    terminal.screen.free()
  }

  const clearSessionMapping = (terminal: RunningTerminal): void => {
    if (terminalsBySession.get(terminal.sessionId) === terminal.terminalId) {
      terminalsBySession.delete(terminal.sessionId)
    }
  }

  /// A regular shell that exited on its own is dead weight once no client is
  /// attached to read its exit frame: it can never be reattached by session
  /// (createTerminal spawns a fresh shell), so drop it with its scrollback.
  const reapIfUnwatched = (terminal: RunningTerminal): void => {
    if (terminal.closed && !terminal.external && terminal.sinks.size === 0) {
      dropTerminal(terminal)
    }
  }

  const stopTerminal = (terminal: RunningTerminal): Promise<void> => {
    const existing = stopping.get(terminal.sessionId)
    if (existing !== undefined) return existing
    const done = Promise.resolve()
      .then(async () => {
        if (terminal.process.stop !== undefined) await terminal.process.stop()
        else if (!terminal.closed) terminal.process.kill()
        terminal.closed = true
        dropTerminal(terminal)
        clearSessionMapping(terminal)
      })
      .finally(() => stopping.delete(terminal.sessionId))
    stopping.set(terminal.sessionId, done)
    return done
  }

  return {
    createTerminal: (request, envOverrides) =>
      Effect.gen(function* () {
        if (stopping.has(request.sessionId)) {
          return yield* Effect.fail(
            new TerminalError({ operation: "createTerminal", message: "Terminal is stopping" })
          )
        }
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
          // A session key only maps to a live terminal or an external one:
          // exited session shells release their key at exit, while external
          // terminals stay attachable after exit (the process is agent-owned
          // and never respawned, but its scrollback and exit frame must
          // still replay to a connecting client).
          return terminalResponse(terminals.get(existingTerminalId)!)
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
        const spawnRequest = prepareSpawn(request, envOverrides)
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
            publishFrame(exitCode === undefined ? { type: "exit" } : { type: "exit", exitCode })
            if (runningTerminal === undefined) {
              exitedBeforeRegistration = true
            } else {
              runningTerminal.closed = true
              clearSessionMapping(runningTerminal)
              reapIfUnwatched(runningTerminal)
            }
          }
        })
        const terminal: RunningTerminal = {
          terminalId,
          sessionId: request.sessionId,
          process,
          sinks: new Set(),
          frames: new ReplayBuffer(),
          clientSeqs: new Map(),
          screen: createTerminalScreen(() => runningTerminal, request),
          sizes: new SizeArbiter({ cols: request.cols, rows: request.rows }),
          removed: false,
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
        // Catch the client up byte for byte while the replay buffer reaches
        // back to its cursor; otherwise send the server's reconstruction of
        // the screen. Replay first: a sink that throws mid-replay must not
        // stay attached.
        const catchUp = replayCovers(terminal, lastOutputSeq)
          ? terminal.frames.since(lastOutputSeq)
          : resyncFrames(terminal)
        // The size first: a client showing a larger PTY than its own screen
        // fits its grid to it before parsing the output laid out for it.
        sink(sizeFrame(terminal.sizes.size))
        for (const frame of catchUp) {
          sink(frame)
        }
        terminal.sinks.add(sink)
        return () => {
          terminal.sinks.delete(sink)
          reapIfUnwatched(terminal)
        }
      }),
    handleClientFrame: (terminalId, frame) =>
      terminalPromise("handleClientFrame", async () => {
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
            if (frame.claim !== false) applySize(terminal, terminal.sizes.claim(frame.clientId))
            terminal.process.write(frame.data)
            break
          }
          case "resize": {
            if (frame.cols < 1 || frame.rows < 1) {
              throw new Error("Terminal dimensions must be positive")
            }
            applySize(
              terminal,
              terminal.sizes.resize(frame.clientId, { cols: frame.cols, rows: frame.rows })
            )
            break
          }
          case "focus": {
            applySize(terminal, terminal.sizes.claim(frame.clientId))
            break
          }
          case "hide": {
            applySize(terminal, terminal.sizes.hide(frame.clientId))
            break
          }
          case "clear": {
            clearTerminal(terminal)
            break
          }
          case "close": {
            await stopTerminal(terminal)
            break
          }
        }
      }),
    releaseClient: (terminalId, clientId) => {
      const terminal = terminals.get(terminalId)
      if (terminal === undefined || terminal.closed) return
      applySize(terminal, terminal.sizes.release(clientId))
    },
    closeTerminal: (terminalId) =>
      terminalPromise("closeTerminal", async () => {
        const terminal = getTerminal(terminalId, "closeTerminal")
        await stopTerminal(terminal)
      }),
    closeTerminalForSession: (sessionId) =>
      terminalPromise("closeTerminalForSession", async () => {
        const terminalId =
          terminalsBySession.get(sessionId) ??
          [...terminalsBySession].find(
            ([key]) => key.toLowerCase() === sessionId.toLowerCase()
          )?.[1]
        if (terminalId === undefined) {
          return false
        }
        // The session mapping only ever points at a registered terminal
        // (closeTerminal and close frames clear the mapping when removing).
        const terminal = getTerminal(terminalId, "closeTerminalForSession")
        if (terminal.closed) {
          // Only external terminals keep their key after exit (to stay
          // attachable for scrollback), so an explicit session close is when
          // they finally get removed.
          if (terminal.process.stop !== undefined) await stopTerminal(terminal)
          dropTerminal(terminal)
          terminalsBySession.delete(sessionId)
          return false
        }
        await stopTerminal(terminal)
        return true
      }),
    closeTerminalsForSessionPrefix: (prefix) =>
      terminalPromise("closeTerminalsForSessionPrefix", async () => {
        let closed = 0
        const pending: Array<Promise<void>> = []
        for (const [sessionId, terminalId] of Array.from(terminalsBySession)) {
          if (!sessionId.toLowerCase().startsWith(prefix.toLowerCase())) continue
          const terminal = terminals.get(terminalId)
          /* v8 ignore next -- defensive: every code path that removes a terminal also clears its session mapping. */
          if (terminal === undefined) continue
          pending.push(stopTerminal(terminal))
          closed += 1
        }
        const results = await Promise.allSettled(pending)
        const failed = results.find((result) => result.status === "rejected")
        if (failed?.status === "rejected") throw failed.reason
        return closed
      }),
    snapshotTerminals: () => ({
      version: 2,
      // Exited session shells are never restored to a session, so persisting
      // them would only carry dead scrollback across restarts forever.
      terminals: [...terminals.values()]
        .filter((terminal) => terminal.external || !terminal.closed)
        .map(snapshotEntry)
    }),
    readScreen: (terminalId, format) =>
      terminalAttempt("readScreen", () => {
        const { screen } = getTerminal(terminalId, "readScreen")
        return format === "text" ? screen.text() : decoder.decode(screen.reconstruct())
      }),
    outputRevision: () => revision,
    subscribeTitles: titles.subscribe,
    restoreTerminals: (snapshot) => {
      for (const entry of snapshot.terminals) {
        if (terminals.has(entry.terminalId)) continue
        const terminal: RunningTerminal = {
          terminalId: entry.terminalId,
          sessionId: entry.sessionId,
          process: noopProcess,
          sinks: new Set(),
          frames: new ReplayBuffer(),
          // Input dedup state is irrelevant to a closed, process-less
          // terminal: external ones ignore input, regular ones refuse it.
          clientSeqs: new Map(),
          // Process-less: nothing to answer terminal queries to.
          screen: createVtTerminal({
            cols: entry.cols ?? RESTORED_TERMINAL_SIZE.cols,
            rows: entry.rows ?? RESTORED_TERMINAL_SIZE.rows
          }),
          sizes: new SizeArbiter(RESTORED_TERMINAL_SIZE),
          removed: false,
          nextOutputSeq: entry.nextOutputSeq,
          closed: true,
          external: entry.external
        }
        restoreEntry(terminal, entry)
        // The process died with the previous server; terminals that were
        // still live at snapshot time replay a synthetic exit so attached
        // clients learn the process is gone rather than waiting on it.
        if (!entry.closed) pushFrame(terminal, { type: "exit" })
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
        frames: new ReplayBuffer(),
        clientSeqs: new Map(),
        // Pipe-fed processes have no size of their own until a client
        // resizes the terminal.
        screen: createTerminalScreen(() => terminal, UNKNOWN_TERMINAL_SIZE),
        sizes: new SizeArbiter(UNKNOWN_TERMINAL_SIZE),
        removed: false,
        nextOutputSeq: 1,
        closed: false,
        external: true
      }
      // A re-registration under the same key replaces the previous terminal
      // (e.g. an agent restarting its dev server): drop the stale one so the
      // mapping never points at output from a dead process.
      const previousId = terminalsBySession.get(config.sessionId)
      const previous = previousId === undefined ? undefined : terminals.get(previousId)
      if (previous !== undefined) dropTerminal(previous)
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
          dropTerminal(terminal)
          clearSessionMapping(terminal)
        }
      }
    }
  }
}

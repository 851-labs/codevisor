import { randomUUID } from "node:crypto"

import { Effect } from "effect"

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

const UNKNOWN_TERMINAL_SIZE = RESTORED_TERMINAL_SIZE
const decoder = new TextDecoder()

const sizeFrame = (size: TerminalSize) =>
  ({ type: "size", seq: 0, cols: size.cols, rows: size.rows }) as const

const applySize = (terminal: RunningTerminal, size: TerminalSize | undefined): void => {
  if (size === undefined) return
  terminal.process.resize(size.cols, size.rows)
  terminal.screen.resize(size.cols, size.rows)
  for (const sink of terminal.sinks) sink(sizeFrame(size))
}

const CLEAR_SCREEN_AND_SCROLLBACK = "\u001b[H\u001b[2J\u001b[3J"
const CLEAR_SCROLLBACK = "\u001b[3J"

export const makeTerminalManager = (config: TerminalManagerConfig = {}): TerminalManagerService => {
  const terminals = new Map<string, RunningTerminal>()
  const terminalsBySession = new Map<string, string>()
  const stopping = new Map<string, Promise<void>>()
  const titles = makeTerminalTitles()
  let revision = 0

  /* v8 ignore next */
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
        const catchUp = replayCovers(terminal, lastOutputSeq)
          ? terminal.frames.since(lastOutputSeq)
          : resyncFrames(terminal)
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
        const terminal = getTerminal(terminalId, "closeTerminalForSession")
        if (terminal.closed) {
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
          /* v8 ignore next */
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
      version: 3,
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
        if (entry.external && snapshot.version < 3) continue
        const terminal: RunningTerminal = {
          terminalId: entry.terminalId,
          sessionId: entry.sessionId,
          process: noopProcess,
          sinks: new Set(),
          frames: new ReplayBuffer(),
          clientSeqs: new Map(),
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
        if (!entry.closed) pushFrame(terminal, { type: "exit" })
        terminals.set(entry.terminalId, terminal)
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
        screen: createTerminalScreen(() => terminal, UNKNOWN_TERMINAL_SIZE),
        sizes: new SizeArbiter(UNKNOWN_TERMINAL_SIZE),
        removed: false,
        nextOutputSeq: 1,
        closed: false,
        external: true
      }
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

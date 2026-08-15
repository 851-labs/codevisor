import { backgroundTerminalKey, DEFAULT_PROMOTION_DELAY_MS } from "@codevisor/agent-runtime"
import { firstLine } from "./internal.js"
import type { CodexCommandTerminal, CodexSession } from "./session.js"

/// Starts a read-only terminal mirror for a command execution. Codex owns the
/// process — we only see its output deltas — so the mirror accepts no input;
/// kill is best-effort via the codex process tree (the protocol has no
/// terminate for agent-run commands). Commands that outlive the promotion
/// delay surface in the `backgroundTasks` snapshot as attachable terminal tabs.
export const openCommandTerminal = (
  session: CodexSession,
  itemId: string,
  command: string,
  source: unknown
): void => {
  const integration = session.backgroundTerminals
  if (integration === undefined || session.commandTerminals.has(itemId)) return
  const terminalKey = backgroundTerminalKey(session.key, itemId)
  const codexPid = session.client.pid
  const stream = integration.registry.register(terminalKey, {
    ...(codexPid === undefined || command.length === 0
      ? {}
      : {
          kill: () => {
            void session.killCommandProcesses(codexPid, command).catch(() => undefined)
          }
        })
  })
  const terminal: CodexCommandTerminal = {
    description: command.length > 0 ? firstLine(command) : "command",
    itemId,
    promoted: false,
    promotionTimer: undefined,
    stream,
    terminalKey
  }
  session.commandTerminals.set(itemId, terminal)
  // unifiedExecStartup is codex explicitly opening a persistent shell — its
  // background-process mechanism — so the tab shows up immediately. Plain
  // agent commands prove themselves by outliving the promotion delay.
  if (source === "unifiedExecStartup") {
    terminal.promoted = true
    emitCodexBackgroundTasks(session)
    return
  }
  terminal.promotionTimer = setTimeout(() => {
    terminal.promotionTimer = undefined
    terminal.promoted = true
    emitCodexBackgroundTasks(session)
  }, integration.promotionDelayMs ?? DEFAULT_PROMOTION_DELAY_MS)
}

export const settleCommandTerminal = (
  session: CodexSession,
  itemId: string,
  item: Record<string, unknown>
): void => {
  const terminal = session.commandTerminals.get(itemId)
  if (terminal === undefined) return
  session.commandTerminals.delete(itemId)
  if (terminal.promotionTimer !== undefined) {
    clearTimeout(terminal.promotionTimer)
    terminal.promotionTimer = undefined
  }
  terminal.stream.exit(typeof item.exitCode === "number" ? item.exitCode : undefined)
  if (terminal.promoted) {
    // The tab stays attachable for scrollback; the task itself is done.
    emitCodexBackgroundTasks(session)
  } else {
    // Short-lived command: nothing was ever surfaced, leave nothing behind.
    terminal.stream.remove()
  }
}

export const emitCodexBackgroundTasks = (session: CodexSession): void => {
  const backgroundTasks = [...session.commandTerminals.values()]
    .filter((terminal) => terminal.promoted)
    .map((terminal) => ({
      description: terminal.description,
      id: terminal.itemId,
      // Codex owns the process; the mirror can neither write nor kill.
      readOnly: true,
      status: "running",
      taskType: "shell",
      terminalKey: terminal.terminalKey,
      toolUseId: terminal.itemId
    }))
  void session.emit({
    kind: "session.updated",
    payload: { backgroundTasks },
    subjectId: session.key
  })
}

/// Connection teardown: the codex process (and every command it ran) is gone;
/// exit the mirrors so attached tabs see the stream end.
export const closeCommandTerminals = (session: CodexSession): void => {
  for (const terminal of [...session.commandTerminals.values()]) {
    if (terminal.promotionTimer !== undefined) {
      clearTimeout(terminal.promotionTimer)
      terminal.promotionTimer = undefined
    }
    terminal.stream.exit(undefined)
    if (!terminal.promoted) {
      terminal.stream.remove()
    }
  }
  session.commandTerminals.clear()
}

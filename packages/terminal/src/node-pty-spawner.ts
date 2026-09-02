import { Effect } from "effect"

import { PORTABLE_TERM } from "./shell.js"
import type { TerminalSpawner } from "./types.js"
import { TerminalError } from "./types.js"

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
          name: request.env.TERM ?? PORTABLE_TERM,
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

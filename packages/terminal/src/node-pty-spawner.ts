import { basename } from "node:path"

import { trackProcessTree } from "@codevisor/processes"
import { Effect } from "effect"

import { PORTABLE_TERM } from "./shell.js"
import type { TerminalSpawner } from "./types.js"
import { TerminalError } from "./types.js"

/* v8 ignore start */
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
        const tracked = trackProcessTree(child.pid, { detached: true })
        child.onData(handlers.onOutput)
        let exited = false
        child.onExit(({ exitCode }) => {
          exited = true
          void tracked
            .then((tree) => tree.stop())
            .finally(() => handlers.onExit(exitCode))
            .catch(() => undefined)
        })
        const tree = await tracked
        return {
          write: (data) => {
            if (!exited) child.write(data)
          },
          resize: (cols, rows) => {
            if (exited) return
            try {
              child.resize(cols, rows)
            } catch {}
          },
          kill: () => {
            void tree.stop().catch(() => child.kill("SIGKILL"))
          },
          stop: () => tree.stop(),
          isShellInForeground: () =>
            basename(child.process).replace(/^-/, "") === basename(request.shell)
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

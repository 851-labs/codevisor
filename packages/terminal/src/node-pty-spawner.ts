import { basename } from "node:path"

import { trackProcessTree } from "@codevisor/processes"
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
        const tracked = trackProcessTree(child.pid, { detached: true })
        child.onData(handlers.onOutput)
        // node-pty closes the pty fd before it reports the exit, and the
        // manager only learns of it after the process tree is stopped. A
        // resize in between (a client disconnecting releases its size)
        // throws "ioctl(2) failed, EBADF" synchronously into the caller —
        // a websocket close listener, where it exits the server.
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
            } catch {
              // The fd closed ahead of the exit event; the exit is on its way.
            }
          },
          kill: () => {
            void tree.stop().catch(() => child.kill("SIGKILL"))
          },
          stop: () => tree.stop(),
          // node-pty reports the foreground process of the PTY's session.
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

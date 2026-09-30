import { Effect } from "effect"
import { expect, it } from "vitest"

import { nodePtySpawner } from "./node-pty-spawner.js"

// A real pty: the failure is the native addon's ioctl on a closed fd.
it("ignores resize and input once the pty's shell has exited", async () => {
  const exited = Promise.withResolvers<number | undefined>()
  const pty = await Effect.runPromise(
    nodePtySpawner.spawn(
      {
        sessionId: "exited-pty",
        shell: "/bin/sh",
        args: ["-c", "exit 3"],
        cwd: "/",
        env: {},
        cols: 80,
        rows: 24
      },
      { onOutput: () => undefined, onExit: exited.resolve }
    )
  )
  expect(await exited.promise).toBe(3)
  // A client disconnecting after the exit releases its size; node-pty used
  // to throw "ioctl(2) failed, EBADF" into the websocket close listener.
  expect(() => pty.resize(100, 30)).not.toThrow()
  expect(() => pty.write("late input")).not.toThrow()
})

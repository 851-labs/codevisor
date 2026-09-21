import { EventEmitter, once } from "node:events"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { connect, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import {
  backgroundTerminalSocketPath,
  shellQuote,
  startBackgroundTerminalHost,
  UNIX_SOCKET_PATH_BUDGET,
  wrapBackgroundCommand,
  type BackgroundTerminalHost,
  type BackgroundTerminalHostRegistry
} from "./background-terminal-host.js"

interface RegisteredTerminal {
  readonly key: string
  readonly controls: {
    readonly write?: (data: string) => void
    readonly kill?: () => void
    readonly stop?: () => Promise<void>
  }
  readonly outputs: Array<string>
  readonly exits: Array<number | undefined>
}

const makeRegistry = (): {
  readonly changes: EventEmitter
  readonly registry: BackgroundTerminalHostRegistry
  readonly registered: Array<RegisteredTerminal>
} => {
  const registered: Array<RegisteredTerminal> = []
  const changes = new EventEmitter()
  return {
    changes,
    registered,
    registry: {
      register: (key, controls) => {
        const entry: RegisteredTerminal = { controls, exits: [], key, outputs: [] }
        registered.push(entry)
        changes.emit("change")
        return {
          exit: (exitCode) => {
            entry.exits.push(exitCode)
            changes.emit("change")
          },
          output: (data) => {
            entry.outputs.push(data)
            changes.emit("change")
          },
          remove: () => undefined
        }
      }
    }
  }
}

const connectWrapper = (socketPath: string): Promise<Socket> =>
  new Promise((resolvePromise, rejectPromise) => {
    const socket = connect(socketPath)
    socket.once("connect", () => resolvePromise(socket))
    socket.once("error", rejectPromise)
  })

const send = (socket: Socket, frame: Record<string, unknown>): void => {
  socket.write(`${JSON.stringify(frame)}\n`)
}

const until = (changes: EventEmitter, predicate: () => boolean): Promise<void> =>
  new Promise((resolve) => {
    const check = () => {
      if (!predicate()) return
      changes.off("change", check)
      resolve()
    }
    changes.on("change", check)
    check()
  })

describe("background terminal host", () => {
  it("awaits a wrapper process tree and reports tracking failures", async () => {
    const { changes, registered, registry } = makeRegistry()
    const stopped = Promise.withResolvers<void>()
    const stop = vi.fn(() => stopped.promise)
    const trackProcess = vi.fn(async () => ({ stop, dispose: () => {} }))
    host = await startBackgroundTerminalHost({
      registry,
      socketPath: makeSocketPath(),
      trackProcess
    })
    const wrapper = await connectWrapper(host.socketPath)
    send(wrapper, { type: "hello", key: "owned", pid: 42 })
    await until(changes, () => registered.length === 1)
    let finished = false
    const closing = registered[0]!.controls.stop!().then(() => {
      finished = true
    })
    expect(finished).toBe(false)
    stopped.resolve()
    await closing
    expect(trackProcess).toHaveBeenCalledWith(42)
    expect(stop).toHaveBeenCalledOnce()
    wrapper.destroy()

    trackProcess.mockRejectedValueOnce(new Error("process table unavailable"))
    const broken = await connectWrapper(host.socketPath)
    send(broken, { type: "hello", key: "broken", pid: 43 })
    await until(changes, () => registered.length === 2)
    await expect(registered[1]!.controls.stop!()).rejects.toThrow("process table unavailable")
    broken.destroy()
  })
  let host: BackgroundTerminalHost | undefined
  const directories: string[] = []
  const makeSocketPath = () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-test-"))
    directories.push(directory)
    return join(directory, "bg.sock")
  }
  afterEach(() => {
    host?.close()
    host = undefined
    for (const directory of directories.splice(0))
      rmSync(directory, { recursive: true, force: true })
  })

  it("bridges wrapper frames to the registry and forwards input/kill back", async () => {
    const { changes, registered, registry } = makeRegistry()
    const socketPath = makeSocketPath()
    // A stale socket file from a previous process gets replaced.
    writeFileSync(socketPath, "")
    host = await startBackgroundTerminalHost({ registry, socketPath })

    const wrapper = await connectWrapper(socketPath)
    const received: Array<Record<string, unknown>> = []
    let buffered = ""
    wrapper.on("data", (chunk: Buffer) => {
      buffered += chunk.toString("utf8")
      for (const line of buffered.split("\n").slice(0, -1)) {
        received.push(JSON.parse(line) as Record<string, unknown>)
      }
      buffered = buffered.split("\n").slice(-1)[0] ?? ""
      changes.emit("change")
    })

    // Frames before (and without) a hello are ignored.
    send(wrapper, { type: "output", data: "too early" })
    // Malformed lines and unknown types are skipped without dropping the stream.
    wrapper.write("not-json\n\n")
    send(wrapper, { type: "mystery" })
    send(wrapper, { type: "hello", key: "session:bg:tool-1", command: "npm run dev" })
    // A second hello is ignored.
    send(wrapper, { type: "hello", key: "session:bg:other" })
    send(wrapper, { type: "output", data: "ready\n" })
    // Output frames without data are skipped.
    send(wrapper, { type: "output" })

    await until(changes, () => (registered[0]?.outputs.length ?? 0) > 0)
    expect(registered).toHaveLength(1)
    expect(registered[0]?.key).toBe("session:bg:tool-1")
    expect(registered[0]?.outputs).toEqual(["ready\n"])

    // Terminal input and kill flow back down to the wrapper.
    registered[0]?.controls.write?.("q")
    registered[0]?.controls.kill?.()
    await until(changes, () => received.length >= 2)
    expect(received).toEqual([{ type: "input", data: "q" }, { type: "kill" }])

    // A clean exit frame carries the code through.
    send(wrapper, { type: "exit", exitCode: 3 })
    await until(changes, () => (registered[0]?.exits.length ?? 0) > 0)
    expect(registered[0]?.exits).toEqual([3])
    // The socket closing afterwards does not double-exit.
    const closed = once(wrapper, "close")
    wrapper.end()
    await closed
    expect(registered[0]?.exits).toEqual([3])
  })

  it("ends the stream when a wrapper dies without an exit frame", async () => {
    const { changes, registered, registry } = makeRegistry()
    const socketPath = makeSocketPath()
    host = await startBackgroundTerminalHost({ registry, socketPath })

    const wrapper = await connectWrapper(socketPath)
    send(wrapper, { type: "hello", key: "session:bg:tool-2", command: "sleep 99" })
    // An exit frame without a code maps to an undefined exit.
    await until(changes, () => registered.length === 1)
    wrapper.destroy()
    await until(changes, () => (registered[0]?.exits.length ?? 0) > 0)
    expect(registered[0]?.exits).toEqual([undefined])
  })

  it("propagates codeless exit frames and rejects on listen failures", async () => {
    const { changes, registered, registry } = makeRegistry()
    const socketPath = makeSocketPath()
    host = await startBackgroundTerminalHost({ registry, socketPath })
    const wrapper = await connectWrapper(socketPath)
    send(wrapper, { type: "hello", key: "session:bg:tool-3" })
    send(wrapper, { type: "exit" })
    await until(changes, () => (registered[0]?.exits.length ?? 0) > 0)
    expect(registered[0]?.exits).toEqual([undefined])
    wrapper.end()

    // Listening on an un-creatable path rejects instead of hanging.
    await expect(
      startBackgroundTerminalHost({ registry, socketPath: "/nonexistent-dir/bg.sock" })
    ).rejects.toBeInstanceOf(Error)
  })

  it("quotes shell arguments and builds wrapped background commands", () => {
    expect(shellQuote("plain")).toBe("'plain'")
    expect(shellQuote("with 'quote'")).toBe("'with '\\''quote'\\'''")

    const wrap = wrapBackgroundCommand({
      nodePath: "/usr/local/bin/node",
      socketPath: "/tmp/bg.sock",
      wrapperPath: "/opt/codevisor/bg-wrap.js"
    })
    const command = wrap("session:bg:tool-9", "npm run dev")
    expect(command).toBe(
      [
        "'/usr/local/bin/node'",
        "'/opt/codevisor/bg-wrap.js'",
        "'/tmp/bg.sock'",
        "'session:bg:tool-9'",
        Buffer.from("npm run dev", "utf8").toString("base64")
      ].join(" ")
    )
  })
})

describe("backgroundTerminalSocketPath", () => {
  it("keeps the socket inside the temp dir when the path fits sun_path", () => {
    expect(backgroundTerminalSocketPath("/var/folders/t", 42, "/fallback")).toBe(
      "/var/folders/t/codevisor-bg-42.sock"
    )
  })

  it("falls back to the system temp dir when the preferred path would overflow", () => {
    // A worktree-scoped TMPDIR such as ~/codevisor/<uuid>/<name>/tmp/runtime/temp.
    const deepTmp = `/${"w".repeat(95)}`
    const path = backgroundTerminalSocketPath(deepTmp, 68425, "/fallback")
    expect(path).toBe("/fallback/codevisor-bg-68425.sock")
    expect(Buffer.byteLength(path)).toBeLessThanOrEqual(UNIX_SOCKET_PATH_BUDGET)
  })

  it("uses the exact budget boundary", () => {
    const name = "codevisor-bg-7.sock"
    // "/" + dir + "/" + name must total exactly the budget.
    const fitting = `/${"x".repeat(UNIX_SOCKET_PATH_BUDGET - name.length - 2)}`
    expect(backgroundTerminalSocketPath(fitting, 7, "/fallback")).toBe(`${fitting}/${name}`)
    expect(backgroundTerminalSocketPath(`${fitting}x`, 7, "/fallback")).toBe(`/fallback/${name}`)
  })

  it("measures the budget in bytes, not characters", () => {
    // 45 two-byte characters: 45 characters but 90 bytes — over budget with the name.
    const multibyte = `/${"é".repeat(45)}`
    expect(backgroundTerminalSocketPath(multibyte, 7, "/fallback")).toBe(
      "/fallback/codevisor-bg-7.sock"
    )
  })

  const rejectingRegistry: BackgroundTerminalHostRegistry = {
    register: () => {
      throw new Error("no wrapper should connect")
    }
  }

  it("rejects when the socket cannot be bound", async () => {
    const root = mkdtempSync(join(tmpdir(), "bg-unbindable-"))
    try {
      // A directory that does not exist fails to bind on every platform.
      await expect(
        startBackgroundTerminalHost({
          socketPath: join(root, "missing", "s.sock"),
          registry: rejectingRegistry
        })
      ).rejects.toThrow()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  // Linux's sun_path is a fixed 108 bytes, so this is deterministic there.
  // Apple's newer kernels accept paths up to PATH_MAX, which is exactly why
  // the budget is the smallest limit among the platforms the server runs on.
  it.runIf(process.platform === "linux")(
    "rejects listening on a path over sun_path, which is why the budget exists",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "bg-long-"))
      try {
        await expect(
          startBackgroundTerminalHost({
            socketPath: join(root, "p".repeat(120), "s.sock"),
            registry: rejectingRegistry
          })
        ).rejects.toThrow()
      } finally {
        rmSync(root, { recursive: true, force: true })
      }
    }
  )
})

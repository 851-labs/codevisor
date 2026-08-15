import { mkdtempSync, writeFileSync } from "node:fs"
import { connect, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  shellQuote,
  startBackgroundTerminalHost,
  wrapBackgroundCommand,
  type BackgroundTerminalHost,
  type BackgroundTerminalHostRegistry
} from "./background-terminal-host.js"

interface RegisteredTerminal {
  readonly key: string
  readonly controls: {
    readonly write?: (data: string) => void
    readonly kill?: () => void
  }
  readonly outputs: Array<string>
  readonly exits: Array<number | undefined>
}

const makeRegistry = (): {
  readonly registry: BackgroundTerminalHostRegistry
  readonly registered: Array<RegisteredTerminal>
} => {
  const registered: Array<RegisteredTerminal> = []
  return {
    registered,
    registry: {
      register: (key, controls) => {
        const entry: RegisteredTerminal = { controls, exits: [], key, outputs: [] }
        registered.push(entry)
        return {
          exit: (exitCode) => entry.exits.push(exitCode),
          output: (data) => entry.outputs.push(data),
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

const until = async (predicate: () => boolean): Promise<void> => {
  for (let attempt = 0; attempt < 200 && !predicate(); attempt += 1) {
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 5))
  }
  expect(predicate()).toBe(true)
}

describe("background terminal host", () => {
  let host: BackgroundTerminalHost | undefined
  afterEach(() => {
    host?.close()
    host = undefined
  })

  it("bridges wrapper frames to the registry and forwards input/kill back", async () => {
    const { registered, registry } = makeRegistry()
    const socketPath = join(mkdtempSync(join(tmpdir(), "codevisor-test-")), "bg.sock")
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

    await until(() => (registered[0]?.outputs.length ?? 0) > 0)
    expect(registered).toHaveLength(1)
    expect(registered[0]?.key).toBe("session:bg:tool-1")
    expect(registered[0]?.outputs).toEqual(["ready\n"])

    // Terminal input and kill flow back down to the wrapper.
    registered[0]?.controls.write?.("q")
    registered[0]?.controls.kill?.()
    await until(() => received.length >= 2)
    expect(received).toEqual([{ type: "input", data: "q" }, { type: "kill" }])

    // A clean exit frame carries the code through.
    send(wrapper, { type: "exit", exitCode: 3 })
    await until(() => (registered[0]?.exits.length ?? 0) > 0)
    expect(registered[0]?.exits).toEqual([3])
    // The socket closing afterwards does not double-exit.
    wrapper.end()
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 30))
    expect(registered[0]?.exits).toEqual([3])
  })

  it("ends the stream when a wrapper dies without an exit frame", async () => {
    const { registered, registry } = makeRegistry()
    const socketPath = join(mkdtempSync(join(tmpdir(), "codevisor-test-")), "bg.sock")
    host = await startBackgroundTerminalHost({ registry, socketPath })

    const wrapper = await connectWrapper(socketPath)
    send(wrapper, { type: "hello", key: "session:bg:tool-2", command: "sleep 99" })
    // An exit frame without a code maps to an undefined exit.
    await until(() => registered.length === 1)
    wrapper.destroy()
    await until(() => (registered[0]?.exits.length ?? 0) > 0)
    expect(registered[0]?.exits).toEqual([undefined])
  })

  it("propagates codeless exit frames and rejects on listen failures", async () => {
    const { registered, registry } = makeRegistry()
    const socketPath = join(mkdtempSync(join(tmpdir(), "codevisor-test-")), "bg.sock")
    host = await startBackgroundTerminalHost({ registry, socketPath })
    const wrapper = await connectWrapper(socketPath)
    send(wrapper, { type: "hello", key: "session:bg:tool-3" })
    send(wrapper, { type: "exit" })
    await until(() => (registered[0]?.exits.length ?? 0) > 0)
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

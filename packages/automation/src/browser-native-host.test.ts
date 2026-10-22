import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"
import { EventEmitter } from "node:events"
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises"
import type { AddressInfo } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"
import { WebSocketServer, type WebSocket } from "ws"

import {
  authenticateNativeHost,
  ensureNativeHostSecret,
  NATIVE_HOST_HANDSHAKE_TIMEOUT_MS,
  NATIVE_HOST_NAME,
  nativeHostNameFor,
  nativeHostProof,
  readNativeHostSecret
} from "./browser-native-host.js"
import { findServerResource } from "./server-resources.js"
import { recordOrEmpty } from "./unknown-values.js"

const CHROME_HOST_MESSAGE_LIMIT = 1024 * 1024
const cleanups: Array<() => Promise<unknown>> = []

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).toReversed()) await cleanup()
})

describe("native host secret", () => {
  it("creates one private secret and keeps reusing it", async () => {
    const dataDir = await temporaryDirectory()

    const secret = ensureNativeHostSecret(dataDir)

    expect(secret).toMatch(/^[0-9a-f]{64}$/)
    expect(ensureNativeHostSecret(dataDir)).toBe(secret)
    expect(readNativeHostSecret(dataDir)).toBe(secret)
    const file = join(dataDir, "browser", "native-host", "secret")
    expect((await stat(file)).mode & 0o777).toBe(0o600)
  })

  it("treats a missing or empty secret file as no secret", async () => {
    const dataDir = await temporaryDirectory()
    expect(readNativeHostSecret(dataDir)).toBeUndefined()

    ensureNativeHostSecret(dataDir)
    await writeFile(join(dataDir, "browser", "native-host", "secret"), "\n")

    expect(readNativeHostSecret(dataDir)).toBeUndefined()
  })
})

describe("native host names", () => {
  it("gives each development worktree its own host so it never shadows the app's", () => {
    expect(nativeHostNameFor(undefined)).toBe(NATIVE_HOST_NAME)
    expect(nativeHostNameFor("  ")).toBe(NATIVE_HOST_NAME)
    expect(nativeHostNameFor("Fudge-Branch 2")).toBe("com.codevisor.dev.fudge_branch_2")
  })
})

describe("native host handshake", () => {
  it("accepts a host that proves the secret and proves the server back", async () => {
    const socket = fakeSocket()
    const authenticated = authenticateNativeHost(socket, "secret")
    const challenge = socket.challenge()

    socket.reply({
      type: "auth",
      nonce: "host-nonce",
      proof: nativeHostProof("secret", "codevisor-native-host", challenge, "host-nonce")
    })

    await expect(authenticated).resolves.toBe(true)
    expect(JSON.parse(socket.sent[1]!)).toEqual({
      type: "ready",
      proof: nativeHostProof("secret", "codevisor-server", "host-nonce", challenge)
    })
    expect(socket.closedWith).toBeUndefined()
  })

  it.each([
    ["a wrong proof", JSON.stringify({ type: "auth", nonce: "n", proof: "0".repeat(64) })],
    ["a short proof", JSON.stringify({ type: "auth", nonce: "n", proof: "0" })],
    ["a command before authenticating", JSON.stringify({ id: 1, method: "Target.getTargets" })],
    ["text that is not JSON", "hello"],
    ["JSON null", "null"]
  ])("closes the socket after %s", async (_name, reply) => {
    const socket = fakeSocket()
    const authenticated = authenticateNativeHost(socket, "secret")

    socket.emit("message", Buffer.from(reply))

    await expect(authenticated).resolves.toBe(false)
    expect(socket.closedWith).toBe(1008)
    expect(socket.sent).toHaveLength(1)
  })

  it("gives up when the host disconnects before answering", async () => {
    const socket = fakeSocket()
    const authenticated = authenticateNativeHost(socket, "secret")

    socket.emit("close")

    await expect(authenticated).resolves.toBe(false)
  })

  it("gives up when the host never answers", async () => {
    vi.useFakeTimers()
    try {
      const socket = fakeSocket()
      const finished = vi.fn()
      const authenticated = authenticateNativeHost(socket, "secret").then(finished)

      await vi.advanceTimersByTimeAsync(NATIVE_HOST_HANDSHAKE_TIMEOUT_MS - 1)
      expect(finished).not.toHaveBeenCalled()
      await vi.advanceTimersByTimeAsync(1)
      await authenticated

      expect(finished).toHaveBeenCalledWith(false)
      expect(socket.closedWith).toBe(1008)
    } finally {
      vi.useRealTimers()
    }
  })
})

describe("native messaging host process", () => {
  it("bridges Chrome and the server, chunking frames past Chrome's 1 MB limit", async () => {
    const dataDir = await temporaryDirectory()
    const server = await nativeServer(ensureNativeHostSecret(dataDir))
    await writePortFile(dataDir, server.port)
    const host = startHost(dataDir)
    const large = largeFrame()

    expect(await host.next()).toEqual({ type: "hello", version: 1 })
    expect(await host.next()).toEqual({ type: "connected" })
    const socket = await server.authenticated
    socket.send('{"id":1,"method":"Target.getTargets"}')
    socket.send(large)

    expect(await host.next()).toBe('{"id":1,"method":"Target.getTargets"}')
    expect(await host.reassembled()).toBe(large)
    expect(Math.max(...host.bodySizes)).toBeLessThan(CHROME_HOST_MESSAGE_LIMIT)

    host.send('{"id":1,"result":{}}')
    host.send({ type: "chunk", id: 1, index: 0, count: 2, data: '{"id":2,' })
    host.send({ type: "chunk", id: 1, index: 1, count: 2, data: '"result":{}}' })
    expect(await server.received(2)).toEqual(['{"id":1,"result":{}}', '{"id":2,"result":{}}'])

    socket.close()
    expect(await host.exitCode).toBe(0)
  })

  it("is turned away by a server that holds a different secret", async () => {
    const dataDir = await temporaryDirectory()
    ensureNativeHostSecret(dataDir)
    const squatter = await nativeServer("a different secret")
    await writePortFile(dataDir, squatter.port)
    const host = startHost(dataDir)

    expect(await host.next()).toEqual({ type: "hello", version: 1 })
    expect(await host.next()).toEqual({
      type: "unavailable",
      reason: "Codevisor closed the native host connection"
    })
    expect(await host.exitCode).toBe(0)
  })

  it("never forwards Chrome traffic to a server whose proof is wrong", async () => {
    const dataDir = await temporaryDirectory()
    ensureNativeHostSecret(dataDir)
    const impostor = await impostorServer()
    await writePortFile(dataDir, impostor.port)
    const host = startHost(dataDir)

    expect(await host.next()).toEqual({ type: "hello", version: 1 })
    expect(await host.next()).toEqual({
      type: "unavailable",
      reason: "Codevisor did not prove it owns this data directory"
    })
    expect(await host.exitCode).toBe(0)
    expect(impostor.messages.map((message) => JSON.parse(message).type)).toEqual(["auth"])
  })

  it("reports that Codevisor is not running when nothing listens on its port", async () => {
    const dataDir = await temporaryDirectory()
    ensureNativeHostSecret(dataDir)
    const server = await nativeServer("unused")
    await writePortFile(dataDir, server.port)
    await server.close()
    const host = startHost(dataDir)

    expect(await host.next()).toEqual({ type: "hello", version: 1 })
    expect(await host.next()).toEqual({
      type: "unavailable",
      reason: `Codevisor is not running on port ${server.port}`
    })
    expect(await host.exitCode).toBe(0)
  })
})

class FakeSocket extends EventEmitter {
  readonly sent: Array<string> = []
  closedWith: number | undefined

  send(data: string) {
    this.sent.push(data)
  }

  close(code?: number) {
    this.closedWith = code
  }

  challenge(): string {
    return String(field(JSON.parse(this.sent[0]!), "nonce"))
  }

  reply(frame: unknown) {
    this.emit("message", Buffer.from(JSON.stringify(frame)))
  }
}

const fakeSocket = (): FakeSocket => new FakeSocket()

const temporaryDirectory = async (): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-native-host-"))
  cleanups.push(() => rm(directory, { recursive: true, force: true }))
  return directory
}

const writePortFile = (dataDir: string, port: number): Promise<void> =>
  writeFile(join(dataDir, "server-port.json"), JSON.stringify({ port, pid: 1, bootId: "test" }))

const largeFrame = (): string =>
  JSON.stringify({
    id: 2,
    result: { data: `"quoted" \\ é 🙂 ${"x".repeat(600_000)}`, html: "<p>".repeat(200_000) }
  })

interface NativeServer {
  readonly port: number
  readonly authenticated: Promise<WebSocket>
  readonly messages: Array<string>
  readonly received: (count: number) => Promise<Array<string>>
  readonly close: () => Promise<void>
}

const listeningServer = async (
  onConnection: (socket: WebSocket, messages: Array<string>, notify: () => void) => void
) => {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 })
  await new Promise<void>((resolve) => server.once("listening", resolve))
  const messages: Array<string> = []
  const waiters = new Set<() => void>()
  const notify = () => {
    for (const waiter of waiters) waiter()
  }
  server.on("connection", (socket) => onConnection(socket, messages, notify))
  let closed: Promise<void> | undefined
  const close = () => {
    closed ??= new Promise<void>((resolve) => {
      for (const client of server.clients) client.terminate()
      server.close(() => resolve())
    })
    return closed
  }
  cleanups.push(close)
  const received = (count: number) =>
    new Promise<Array<string>>((resolve) => {
      const check = () => {
        if (messages.length < count) return
        waiters.delete(check)
        resolve(messages.slice(0, count))
      }
      waiters.add(check)
      check()
    })
  return { port: listeningPort(server.address()), messages, received, close }
}

const listeningPort = (address: AddressInfo | string | null): number => {
  if (typeof address !== "object" || address === null) throw new Error("Server is not listening")
  return address.port
}

const nativeServer = async (secret: string): Promise<NativeServer> => {
  const authenticated = Promise.withResolvers<WebSocket>()
  const server = await listeningServer((socket, messages, notify) => {
    void authenticateNativeHost(socket, secret).then((ok) => {
      if (!ok) return
      socket.on("message", (data: Buffer) => {
        messages.push(data.toString())
        notify()
      })
      authenticated.resolve(socket)
    })
  })
  return { ...server, authenticated: authenticated.promise }
}

const impostorServer = () =>
  listeningServer((socket, messages, notify) => {
    socket.on("message", (data: Buffer) => {
      messages.push(data.toString())
      notify()
      socket.send(JSON.stringify({ type: "ready", proof: "0".repeat(64) }))
    })
    socket.send(JSON.stringify({ type: "challenge", nonce: "server-nonce" }))
  })

interface HostProcess {
  readonly next: () => Promise<unknown>
  readonly reassembled: () => Promise<string>
  readonly send: (message: unknown) => void
  readonly bodySizes: Array<number>
  readonly exitCode: Promise<number | null>
}

const startHost = (dataDir: string): HostProcess => {
  const script = findServerResource("native-host/codevisor-native-host.mjs")!
  const child = spawn(process.execPath, [script, dataDir], { stdio: "pipe" })
  cleanups.push(async () => {
    if (child.exitCode === null) child.kill()
  })
  const reader = hostOutput(child)
  return {
    ...reader,
    send: (message) => child.stdin.write(nativeMessage(message)),
    exitCode: new Promise((resolve) => child.once("exit", resolve))
  }
}

const hostOutput = (child: ChildProcessWithoutNullStreams) => {
  const queue: Array<unknown> = []
  const bodySizes: Array<number> = []
  const waiters: Array<(message: unknown) => void> = []
  let buffered = Buffer.alloc(0)
  child.stdout.on("data", (data: Buffer) => {
    buffered = Buffer.concat([buffered, data])
    while (buffered.length >= 4 && buffered.length >= 4 + buffered.readUInt32LE(0)) {
      const length = buffered.readUInt32LE(0)
      bodySizes.push(length)
      const message: unknown = JSON.parse(buffered.subarray(4, 4 + length).toString("utf8"))
      buffered = buffered.subarray(4 + length)
      const waiter = waiters.shift()
      if (waiter === undefined) queue.push(message)
      else waiter(message)
    }
  })
  const next = (): Promise<unknown> => {
    if (queue.length > 0) return Promise.resolve(queue.shift())
    return new Promise((resolve) => waiters.push(resolve))
  }
  const reassembled = async (): Promise<string> => {
    const parts: Array<string> = []
    for (;;) {
      const chunk = await next()
      parts[Number(field(chunk, "index"))] = String(field(chunk, "data"))
      if (field(chunk, "index") === Number(field(chunk, "count")) - 1) return parts.join("")
    }
  }
  return { next, reassembled, bodySizes }
}

const nativeMessage = (message: unknown): Buffer => {
  const body = Buffer.from(JSON.stringify(message), "utf8")
  const header = Buffer.alloc(4)
  header.writeUInt32LE(body.length)
  return Buffer.concat([header, body])
}

const field = (value: unknown, name: string): unknown => recordOrEmpty(value)[name]

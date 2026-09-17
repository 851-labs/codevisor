import { EventEmitter } from "node:events"
import { PassThrough } from "node:stream"

import { afterEach, expect, it, vi } from "vitest"

import { makeNdjsonTransport, type StdioEndpoint } from "./stdio-transport.js"

const workers = vi.hoisted(() => ({ instances: [] as WorkerDouble[] }))
interface WorkerDouble extends EventEmitter {
  postMessage: ReturnType<typeof vi.fn>
  terminate: ReturnType<typeof vi.fn>
}
vi.mock("node:worker_threads", async () => {
  const { EventEmitter } = await import("node:events")
  return {
    parentPort: Object.assign(new EventEmitter(), { postMessage: vi.fn() }),
    Worker: class extends EventEmitter {
      postMessage = vi.fn()
      terminate = vi.fn().mockResolvedValue(0)
      constructor() {
        super()
        workers.instances.push(this)
      }
    }
  }
})

afterEach(() => {
  workers.instances.length = 0
  vi.restoreAllMocks()
})

const fixture = () => {
  const stdin = new PassThrough()
  const stdout = new PassThrough()
  const stderr = new PassThrough()
  let exit: (error?: Error) => void = () => {}
  const endpoint: StdioEndpoint = {
    stdin,
    stdout,
    stderr,
    pid: 123,
    onExit: (handler) => {
      exit = handler
    },
    kill: vi.fn()
  }
  return { endpoint, stdin, stdout, stderr, exit: (error?: Error) => exit(error) }
}

it("bounds queued worker input and drains replies before reporting process exit", ({
  onTestFinished
}) => {
  const child = fixture()
  const transport = makeNdjsonTransport(child.endpoint, { isolateCodexHistory: true })
  onTestFinished(() => transport.close())
  const worker = workers.instances.at(-1)!
  const messages = vi.fn()
  const failures = vi.fn()
  transport.onMessage!(messages)
  transport.onFailure(failures)
  const pause = vi.spyOn(child.stdout, "pause")
  const resume = vi.spyOn(child.stdout, "resume")
  const chunk = "x".repeat(1024 * 1024)
  child.stdout.emit("data", chunk)
  expect(worker.postMessage).toHaveBeenCalledWith({ chunk }, [])
  expect(pause).toHaveBeenCalledOnce()
  child.exit(new Error("process ended"))
  expect(failures).not.toHaveBeenCalled()
  worker.emit("message", { consumed: 256 * 1024 })
  expect(resume).not.toHaveBeenCalled()
  worker.emit("message", { message: { id: 1, result: "complete" } })
  expect(messages).toHaveBeenCalledWith({ id: 1, result: "complete" })
  worker.emit("message", { consumed: 768 * 1024 })
  expect(resume).toHaveBeenCalledOnce()
  expect(failures).toHaveBeenCalledExactlyOnceWith(new Error("process ended"))
  expect(worker.terminate).toHaveBeenCalledOnce()
  worker.emit("message", { message: { id: 2 } })
  child.stdout.emit("data", "late")
  worker.emit("exit", 0)
  expect(messages).toHaveBeenCalledOnce()
  expect(worker.postMessage).toHaveBeenCalledOnce()
  const lateFailure = vi.fn()
  transport.onFailure(lateFailure)
  expect(lateFailure).toHaveBeenCalledExactlyOnceWith(new Error("process ended"))
})

it("supports line consumers and reports a worker crash once", ({ onTestFinished }) => {
  const child = fixture()
  const transport = makeNdjsonTransport(child.endpoint, { isolateCodexHistory: true })
  onTestFinished(() => transport.close())
  const worker = workers.instances.at(-1)!
  worker.emit("message", { message: { id: 0 } })
  const lines = vi.fn()
  const failures = vi.fn()
  transport.onLine(lines)
  transport.onFailure(failures)
  child.stdout.emit("data", "small")
  worker.emit("message", { message: { id: 1 } })
  worker.emit("message", { consumed: 5 })
  expect(lines).toHaveBeenCalledExactlyOnceWith('{"id":1}')
  worker.emit("exit", 2)
  expect(failures).toHaveBeenCalledExactlyOnceWith(new Error("Agent output worker exited (2)"))
  worker.emit("error", new Error("late worker error"))
  expect(failures).toHaveBeenCalledOnce()
  expect(transport.isOpen()).toBe(false)
})

it("joins incomplete lines once and handles deliberate teardown of an already closed pipe", () => {
  const child = fixture()
  const transport = makeNdjsonTransport({ ...child.endpoint, stderr: undefined })
  const lines = vi.fn()
  transport.onLine(lines)
  child.stdout.emit("data", '{"a":')
  child.stdout.emit("data", "1}\n{}\npartial")
  expect(lines.mock.calls).toEqual([['{"a":1}'], ["{}"]])
  vi.spyOn(child.stdin, "end").mockImplementation(() => {
    throw new Error("closed")
  })
  transport.close()
  child.exit()
  expect(child.endpoint.kill).toHaveBeenCalledOnce()
  expect(transport.isOpen()).toBe(false)
})

it("turns a synchronous non-Error write failure into a session failure", ({ onTestFinished }) => {
  const child = fixture()
  const transport = makeNdjsonTransport(child.endpoint)
  onTestFinished(() => transport.close())
  vi.spyOn(child.stdin, "write").mockImplementation(() => {
    throw "broken pipe"
  })
  const failures = vi.fn()
  transport.onFailure(failures)
  transport.send({ id: 1 })
  expect(failures).toHaveBeenCalledExactlyOnceWith(new Error("broken pipe"))
})

it("parses worker frames across chunks, skips diagnostics, and acknowledges every chunk", async () => {
  const { parentPort } = await import("node:worker_threads")
  const port = parentPort! as unknown as WorkerDouble
  await import("./ndjson-worker.js")
  try {
    const chunks = [
      'diagnostic\n{"id":1,"result":{"thread":{"turns":[',
      '{"text":"history"}],"id":"thread"}}}\n{"method":',
      '"ready"}\n',
      ""
    ]
    for (const chunk of chunks) port.emit("message", { chunk })
    expect(port.postMessage.mock.calls.map(([message]) => message)).toEqual([
      { consumed: chunks[0]!.length },
      { message: { id: 1, result: { thread: { turns: [], id: "thread" } } } },
      { consumed: chunks[1]!.length },
      { message: { method: "ready" } },
      { consumed: chunks[2]!.length },
      { consumed: 0 }
    ])
  } finally {
    port.removeAllListeners()
  }
})

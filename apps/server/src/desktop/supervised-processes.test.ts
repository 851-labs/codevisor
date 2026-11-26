import { createServer, type Socket } from "node:net"

import { describe, expect, it, onTestFinished } from "vitest"

import { type Ended, SupervisedProcesses } from "./supervised-processes.js"

const stayingAlive = "setInterval(() => undefined, 1000)"

const helperThatConnects = (port: number): string =>
  `require("node:net").connect(${port}, "127.0.0.1"); ${stayingAlive}`

const sessionThatStarts = (helper: string): string =>
  `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(helper)}], { stdio: "ignore" }); ${stayingAlive}`

const listening = async () => {
  const connected = Promise.withResolvers<Socket>()
  const server = createServer((socket) => connected.resolve(socket))
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())))
  const address = server.address()
  const port = typeof address === "object" && address !== null ? address.port : 0
  return { port, connected: connected.promise }
}

const closed = (socket: Socket): Promise<void> =>
  new Promise((resolve) => {
    socket.once("close", () => resolve())
    socket.on("error", () => undefined)
  })

describe("the processes a desktop is made of", () => {
  it("are stopped together with what they started, and stopping waits for them", async () => {
    const processes = new SupervisedProcesses(() => undefined)
    onTestFinished(() => processes.stop())
    const { port, connected } = await listening()
    const session = processes.start(
      process.execPath,
      ["-e", sessionThatStarts(helperThatConnects(port))],
      {}
    )
    const helper = await connected
    const helperGone = closed(helper)

    await processes.stop()
    expect(session.exitCode !== null || session.signalCode !== null).toBe(true)
    await helperGone
  })

  it("report the one that ends by itself, and say nothing about those it stops", async () => {
    const ends: Ended[] = []
    const ended = Promise.withResolvers<void>()
    const processes = new SupervisedProcesses((end) => {
      ends.push(end)
      ended.resolve()
    })
    onTestFinished(() => processes.stop())
    processes.start(process.execPath, ["-e", stayingAlive], {})
    processes.start(process.execPath, ["-e", "process.exit(3)"], {})
    await ended.promise
    await processes.stop()
    expect(ends).toEqual([{ program: process.execPath, reason: "stopped (exit 3)" }])
  })

  it("report a program that isn't installed", async () => {
    const ended = Promise.withResolvers<Ended>()
    const processes = new SupervisedProcesses((end) => ended.resolve(end))
    onTestFinished(() => processes.stop())
    processes.start("no-such-desktop-program", [], {})
    expect(await ended.promise).toMatchObject({
      program: "no-such-desktop-program",
      reason: expect.stringContaining("couldn't start")
    })
  })
})

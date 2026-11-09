import { fork } from "node:child_process"
import { once } from "node:events"
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it } from "vitest"

for (const asynchronous of [false, true]) {
  it(`cloud variables retain ${asynchronous ? "asynchronous capture" : "synchronous discovery"}`, async () => {
    const fixture = await mkdtemp(join(tmpdir(), "codevisor-cloud-variables-"))
    let connection: import("node:net").Socket | undefined
    let child: import("node:child_process").ChildProcess | undefined
    let closed: Promise<unknown> | undefined
    let watchdog: ReturnType<typeof setTimeout> | undefined
    let cleaning = false
    const server = createServer()
    try {
      await mkdir(join(fixture, "apps/cloud"), { recursive: true })
      await writeFile(join(fixture, "apps/cloud/.dev.vars"), 'VALUE="local=content"\n')
      await writeFile(
        join(fixture, "git"),
        `#!${process.execPath}
const assert = require("node:assert/strict")
const fs = require("node:fs")
const net = require("node:net")
assert.deepEqual(process.argv.slice(2), ["rev-parse", "--git-common-dir"])
const socket = net.connect(Number(process.env.CLOUD_TEST_GATE), "127.0.0.1")
socket.on("connect", () => socket.write("ready"))
socket.once("data", () => {
  fs.writeFileSync("finished", "yes")
  process.stdout.write(".git\\n")
  socket.end()
})
socket.on("close", () => process.exit())
`,
        { mode: 0o700 }
      )
      const probe = join(fixture, "probe.mjs")
      await writeFile(
        probe,
        `import { existsSync } from "node:fs"
import { makeCommandRunner } from ${JSON.stringify(new URL("./commands.ts", import.meta.url).href)}
import { readCloudDevVariables } from ${JSON.stringify(new URL("./dev-cloud.ts", import.meta.url).href)}
queueMicrotask(() => process.send({ finished: existsSync("finished") }))
const variables = await readCloudDevVariables(process.cwd(), ${asynchronous ? "makeCommandRunner(process.cwd()).capture" : "undefined"})
process.send({ variables })
process.disconnect()
`
      )
      let ready = false
      let pulse: { finished: boolean } | undefined
      let variables: unknown
      const release = () => {
        if (ready && (!asynchronous || pulse !== undefined)) connection?.end("release")
      }
      server.on("connection", (socket) => {
        if (cleaning) {
          socket.destroy()
          return
        }
        connection = socket
        socket.once("data", () => {
          ready = true
          release()
        })
      })
      server.listen(0, "127.0.0.1")
      await once(server, "listening")
      child = fork(probe, [], {
        cwd: fixture,
        env: {
          ...process.env,
          PATH: fixture,
          CLOUD_TEST_GATE: String(gatePort(server))
        },
        stdio: ["ignore", "ignore", "pipe", "ipc"]
      })
      const spawned = child
      closed = new Promise((done) => spawned.once("close", (code, signal) => done([code, signal])))
      const completed = once(child, "close")
      let stderr = ""
      child.stderr?.on("data", (chunk) => (stderr += chunk))
      child.on("message", (message: { finished: boolean } | { variables: unknown }) => {
        if ("finished" in message) {
          pulse = { finished: message.finished }
          if (asynchronous) release()
        } else variables = message.variables
      })
      watchdog = setTimeout(() => {
        connection?.destroy()
        child?.kill("SIGKILL")
      }, 15_000)
      expect(await completed, stderr).toEqual([0, null])
      expect(ready).toBe(true)
      expect(pulse?.finished).toBe(!asynchronous)
      expect(variables).toEqual({ VALUE: "local=content" })
    } finally {
      clearTimeout(watchdog)
      cleaning = true
      connection?.destroy()
      try {
        if (child?.pid && child.exitCode === null && child.signalCode === null)
          child.kill("SIGKILL")
        if (closed) await closed
      } finally {
        try {
          await new Promise((done) => server.close(() => done(undefined)))
        } finally {
          await rm(fixture, { recursive: true, force: true })
        }
      }
    }
  })
}

function gatePort(server: import("node:net").Server): number {
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("expected a TCP address")
  return address.port
}

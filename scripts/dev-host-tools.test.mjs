import assert from "node:assert/strict"
import { fork } from "node:child_process"
import { once } from "node:events"
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises"
import { createServer } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"

for (const asynchronous of [false, true]) {
  test(`cloud variables retain ${asynchronous ? "asynchronous capture" : "synchronous discovery"}`, async () => {
    const fixture = await mkdtemp(join(tmpdir(), "codevisor-cloud-variables-"))
    let connection
    let child
    let closed
    let watchdog
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
import { makeCommandRunner, readCloudDevVariables } from ${JSON.stringify(new URL("./dev-host-tools.mjs", import.meta.url).href)}
queueMicrotask(() => process.send({ finished: existsSync("finished") }))
const variables = await readCloudDevVariables(process.cwd(), ${asynchronous ? "makeCommandRunner(process.cwd()).capture" : "undefined"})
process.send({ variables })
process.disconnect()
`
      )
      let ready = false
      let pulse
      let variables
      const release = () => {
        if (ready && (!asynchronous || pulse !== undefined)) connection.end("release")
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
        env: { ...process.env, PATH: fixture, CLOUD_TEST_GATE: String(server.address().port) },
        stdio: ["ignore", "ignore", "pipe", "ipc"]
      })
      closed = new Promise((done) => child.once("close", (code, signal) => done([code, signal])))
      const completed = once(child, "close")
      let stderr = ""
      child.stderr.on("data", (chunk) => (stderr += chunk))
      child.on("message", (message) => {
        if ("finished" in message) {
          pulse = message
          if (asynchronous) release()
        } else variables = message.variables
      })
      watchdog = setTimeout(() => {
        connection?.destroy()
        child.kill("SIGKILL")
      }, 15_000)
      assert.deepEqual(await completed, [0, null], stderr)
      assert.equal(ready, true)
      assert.equal(pulse?.finished, !asynchronous)
      assert.deepEqual(variables, { VALUE: "local=content" })
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
          await new Promise((done) => server.close(done))
        } finally {
          await rm(fixture, { recursive: true, force: true })
        }
      }
    }
  })
}

import { mkdtempSync, readFileSync } from "node:fs"
import { createServer, type Server } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { makeWorld } from "../src/cli/support-test-support.js"
import { resolvePort, statusCommand } from "../src/cli/support.js"
import { claimServeListener } from "../src/serve-listener.js"
import {
  defaultServerConfig,
  startCodevisorServer,
  type RunningCodevisorServer
} from "../src/server.js"
import { run } from "../src/test-support-agents.js"
import { listeningPort } from "../src/test-support-net.js"
import { makeServices, runningServers, tempDirs } from "../src/test-support.js"

const blockers: Array<Server> = []

afterEach(async () => {
  for (const blocker of blockers.splice(0)) {
    await new Promise<void>((resolve) => blocker.close(() => resolve()))
  }
})

const occupyPort = async (): Promise<number> => {
  const blocker = createServer()
  blockers.push(blocker)
  await new Promise<void>((resolve) => blocker.listen(0, "127.0.0.1", resolve))
  return listeningPort(blocker)
}

const dataDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-port-fallback-"))
  tempDirs.push(directory)
  return directory
}

const startServer = async (
  dataDir: string,
  preferredPort: number
): Promise<RunningCodevisorServer> => {
  const { services } = await makeServices()
  const { listener } = await claimServeListener({
    args: { "preferred-port": String(preferredPort) },
    env: {},
    dataDir,
    boot: {
      host: "127.0.0.1",
      version: "0.1.0",
      bootId: "boot-fallback",
      processId: process.pid,
      appOwned: false,
      serviceManaged: false,
      log: () => undefined
    }
  })
  const config = defaultServerConfig({ port: listener.port, bootId: "boot-fallback" })
  const server = await run(startCodevisorServer(services, config, listener))
  runningServers.push(server)
  return server
}

const stopServer = async (server: RunningCodevisorServer): Promise<void> => {
  runningServers.splice(runningServers.indexOf(server), 1)
  await run(server.close)
}

const cliFor = (dataDir: string) => {
  const world = makeWorld()
  const deps = {
    ...world.deps,
    dataDir,
    readTextFile: (path: string) => readFileSync(path, "utf8"),
    fetchJson: async (url: string) => {
      const response = await fetch(url)
      return { status: response.status, body: await response.json() }
    }
  }
  return { deps, logs: world.logs }
}

describe("listening port fallback", () => {
  it("starts on another port when the preferred one is taken, and the CLI finds it", async () => {
    const blocked = await occupyPort()
    const dataDir = dataDirectory()

    const server = await startServer(dataDir, blocked)

    expect(server.port).toBeGreaterThan(blocked)
    expect(await (await fetch(`http://127.0.0.1:${server.port}/v1/health`)).json()).toMatchObject({
      ok: true
    })
    const cli = cliFor(dataDir)
    expect(await resolvePort(cli.deps)).toBe(server.port)
    expect(await statusCommand(cli.deps, { json: true })).toBe(0)
    expect(JSON.parse(cli.logs.at(-1)!)).toMatchObject({ running: true, port: server.port })
  })

  it("comes back on the same port after a restart", async () => {
    const blocked = await occupyPort()
    const dataDir = dataDirectory()
    const first = await startServer(dataDir, blocked)
    await stopServer(first)

    const second = await startServer(dataDir, blocked)

    expect(second.port).toBe(first.port)
  })
})

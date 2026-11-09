import { spawn } from "node:child_process"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { createServer, type RequestListener, type Server } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { delay, describeExit, waitForClose, waitForExit } from "./child-processes.ts"
import { colorFromHash } from "./color.ts"
import { claimedServerPort, shutdownDevServers, waitForHealth } from "./dev-servers.ts"
import { directoryIsEmpty, pathExists } from "./files.ts"
import { findAvailablePort, isPortAvailable, parsePort } from "./ports.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

const scratch = async () => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-devtools-test-"))
  cleanups.push(() => rm(directory, { recursive: true, force: true }))
  return directory
}

const listen = async (
  handler: RequestListener,
  host = "127.0.0.1"
): Promise<{ server: Server; port: number }> => {
  const server = createServer(handler)
  await new Promise<void>((resolve) => server.listen(0, host, resolve))
  cleanups.push(() => new Promise((resolve) => server.close(resolve)))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("expected a TCP address")
  return { server, port: address.port }
}

const sleeper = () => {
  const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"])
  cleanups.push(async () => child.kill("SIGKILL"))
  return child
}

describe("colorFromHash", () => {
  it("derives a stable color from a hash", () => {
    expect(colorFromHash("00000000")).toEqual({
      hex: "#d62929",
      composer: "extended-srgb:0.84000,0.16000,0.16000,1.00000"
    })
    expect(colorFromHash("abcdef12")).toEqual(colorFromHash("abcdef12"))
    expect(
      new Set(
        ["00000040", "00000080", "000000c0", "00000100", "00000140"].map(
          (hash) => colorFromHash(hash).hex
        )
      ).size
    ).toBe(5)
  })
})

describe("ports", () => {
  it("parses user ports and rejects others", () => {
    expect(parsePort(undefined, "PORT")).toBeUndefined()
    expect(parsePort("4000", "PORT")).toBe(4000)
    expect(() => parsePort("80", "PORT")).toThrow(
      /PORT must be an integer from 1024 through 65535; received 80/
    )
  })

  it("skips a busy port when finding one", async () => {
    const { port } = await listen(() => {}, "0.0.0.0")
    expect(await isPortAvailable(port)).toBe(false)

    const found = await findAvailablePort(port, port, 50)
    expect(found).toBeGreaterThan(port)
    expect(found).toBeLessThan(port + 50)
    await expect(findAvailablePort(port, port, 1)).rejects.toThrow(
      /No available Codevisor development port/
    )
  })
})

describe("files", () => {
  it("reports existing paths and empty or missing directories", async () => {
    const directory = await scratch()
    expect(await pathExists(directory)).toBe(true)
    expect(await pathExists(join(directory, "missing"))).toBe(false)
    expect(await directoryIsEmpty(directory)).toBe(true)
    expect(await directoryIsEmpty(join(directory, "missing"))).toBe(true)

    await writeFile(join(directory, "file"), "")
    expect(await directoryIsEmpty(directory)).toBe(false)
    await expect(directoryIsEmpty(join(directory, "file"))).rejects.toMatchObject({
      code: "ENOTDIR"
    })
  })
})

describe("child processes", () => {
  it("resolves exit and close, including for a child that already exited", async () => {
    const child = spawn(process.execPath, ["-e", "process.exit(3)"])
    const closed = waitForClose(child)
    expect(await waitForExit(child)).toEqual({ code: 3, signal: null })
    expect(await closed).toEqual({ code: 3, signal: null })
    expect(await waitForExit(child)).toEqual({ code: 3, signal: null })
  })

  it("describes exits and waits", async () => {
    expect(describeExit({ code: 2, signal: null })).toBe("code 2")
    expect(describeExit({ code: null, signal: null })).toBe("code 1")
    expect(describeExit({ code: null, signal: "SIGTERM" })).toBe("signal SIGTERM")
    await delay(1)
  })
})

describe("dev servers", () => {
  it("waits until a server reports healthy", async () => {
    let healthy = false
    const { port } = await listen((_request, response) => {
      response.statusCode = healthy ? 200 : 503
      response.end()
    })
    setTimeout(() => (healthy = true), 50)

    await waitForHealth(() => port, sleeper())
  })

  it("stops waiting when the server exits or never becomes healthy", async () => {
    const exited = spawn(process.execPath, ["-e", "process.exit(0)"])
    await waitForExit(exited)
    await expect(waitForHealth(1, exited)).rejects.toThrow(/exited before becoming healthy/)

    const { port } = await listen((_request, response) => {
      response.statusCode = 503
      response.end()
    })
    await expect(waitForHealth(port, sleeper(), 1)).rejects.toThrow(/Timed out waiting/)
  })

  it("reads the port a server claimed and falls back otherwise", async () => {
    const directory = await scratch()
    expect(claimedServerPort(directory, 4000)).toBe(4000)
    await writeFile(join(directory, "server-port.json"), JSON.stringify({ port: 4321 }))
    expect(claimedServerPort(directory, 4000)).toBe(4321)
    await writeFile(join(directory, "server-port.json"), JSON.stringify({ port: -1 }))
    expect(claimedServerPort(directory, 4000)).toBe(4000)
  })

  it("asks servers to shut down and terminates the ones that don't answer", async () => {
    const shutdowns: Array<string> = []
    const answering = sleeper()
    const { port } = await listen((request, response) => {
      shutdowns.push(request.url ?? "")
      answering.kill("SIGTERM")
      response.end()
    })
    const silent = sleeper()

    await shutdownDevServers([
      [port, answering],
      [1, silent]
    ])

    expect(shutdowns).toEqual(["/v1/shutdown"])
    expect((await waitForExit(silent)).signal).toBe("SIGTERM")
  })
})

import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  DEFAULT_LISTEN_PORT,
  listenCandidates,
  listenPortArgs,
  listenPortFile,
  readListenPort,
  recordListenPort,
  resolveListenPortPlan
} from "./listen-port.js"

const directories: Array<string> = []
const dataDir = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-listen-port-"))
  directories.push(directory)
  return directory
}

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true })
})

describe("listen port plan", () => {
  it("tries the last port, then 49361 and the rest of its range, then any free port", () => {
    const plan = resolveListenPortPlan({}, {}, 49370)
    const candidates = listenCandidates(plan)

    expect(candidates.slice(0, 3)).toEqual([49370, 49361, 49362])
    expect(candidates.filter((port) => port === 49370)).toHaveLength(1)
    expect(candidates.at(-2)).toBe(49399)
    expect(candidates.at(-1)).toBe(0)
    expect(listenCandidates(resolveListenPortPlan({}, {}, undefined))[0]).toBe(DEFAULT_LISTEN_PORT)
  })

  it("pins --port or CODEVISOR_PORT exactly, with no fallback", () => {
    expect(listenCandidates(resolveListenPortPlan({ port: "5000" }, {}, 49370))).toEqual([5000])
    expect(listenCandidates(resolveListenPortPlan({}, { CODEVISOR_PORT: "6000" }, 49370))).toEqual([
      6000
    ])
    expect(listenCandidates(resolveListenPortPlan({ port: "0" }, {}, undefined))).toEqual([0])
    expect(resolveListenPortPlan({ port: "" }, { CODEVISOR_PORT: " " }, undefined).kind).toBe(
      "automatic"
    )
  })

  it("starts the range at --preferred-port and keeps it below the highest port", () => {
    const candidates = listenCandidates(
      resolveListenPortPlan({ "preferred-port": "65530" }, {}, undefined)
    )
    expect(candidates).toEqual([65530, 65531, 65532, 65533, 65534, 65535, 0])
  })

  it("rejects ports that cannot be bound", () => {
    expect(() => resolveListenPortPlan({ port: "http" }, {}, undefined)).toThrow(
      '--port must be a port number from 0 to 65535, not "http"'
    )
    expect(() => resolveListenPortPlan({ "preferred-port": "0" }, {}, undefined)).toThrow(
      '--preferred-port must be a port number from 1 to 65535, not "0"'
    )
  })

  it("restarts with the same pin or preference, and lets the port file keep it sticky", () => {
    expect(listenPortArgs(resolveListenPortPlan({ port: "5000" }, {}, undefined))).toEqual([
      "--port",
      "5000"
    ])
    expect(listenPortArgs(resolveListenPortPlan({}, {}, 49370))).toEqual([])
    expect(
      listenPortArgs(resolveListenPortPlan({ "preferred-port": "51000" }, {}, undefined))
    ).toEqual(["--preferred-port", "51000"])
  })
})

describe("listen port file", () => {
  it("records the claimed port atomically and reads it back", () => {
    const directory = dataDir()
    expect(readListenPort(directory)).toBeUndefined()

    recordListenPort(directory, { port: 49363, pid: 42, bootId: "boot-1" })

    expect(readListenPort(directory)).toBe(49363)
  })

  it("ignores a stale or damaged file", () => {
    const directory = dataDir()
    for (const contents of ["{not json", '{"port":0}', '{"port":70000}', '{"port":"49361"}']) {
      writeFileSync(listenPortFile(directory), contents)
      expect(readListenPort(directory)).toBeUndefined()
    }
  })
})

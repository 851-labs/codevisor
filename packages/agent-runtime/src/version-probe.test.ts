import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  unlinkSync,
  utimesSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { binaryIdentity, makeVersionProber, parseVersionOutput } from "./version-probe.js"

describe("parseVersionOutput", () => {
  it("extracts the first semver-ish token", () => {
    expect(parseVersionOutput("claude 2.1.5 (Claude Code)")).toBe("2.1.5")
    expect(parseVersionOutput("codex-cli 0.48.0-alpha.2\n")).toBe("0.48.0-alpha.2")
    expect(parseVersionOutput("v1.2")).toBe("1.2")
    expect(parseVersionOutput("no version here")).toBeUndefined()
  })
})

describe("makeVersionProber", () => {
  const cleanups: Array<() => void> = []
  afterEach(() => {
    for (const cleanup of cleanups.splice(0)) cleanup()
  })

  it("caches by path + identity and re-probes when the binary changes", async () => {
    let reads = 0
    let identity = "a"
    const prober = makeVersionProber({
      readVersionOutput: () => {
        reads += 1
        return Promise.resolve(`tool ${reads}.0.0`)
      },
      identity: () => identity
    })

    expect(prober.get("/bin/tool")).toBeUndefined()
    await prober.probe(["/bin/tool"])
    expect(prober.get("/bin/tool")).toBe("1.0.0")

    await prober.probe(["/bin/tool", "/bin/tool"])
    expect(reads).toBe(1)

    identity = "b"
    await prober.probe(["/bin/tool"])
    expect(prober.get("/bin/tool")).toBe("2.0.0")
  })

  it("shares in-flight probes and never rejects on failures", async () => {
    let reads = 0
    let release: (() => void) | undefined
    const prober = makeVersionProber({
      readVersionOutput: () => {
        reads += 1
        return new Promise((resolve) => {
          release = () => resolve("tool 3.1.4")
        })
      },
      identity: () => "a"
    })
    const first = prober.probe(["/bin/tool"])
    const second = prober.probe(["/bin/tool"])
    release?.()
    await Promise.all([first, second])
    expect(reads).toBe(1)
    expect(prober.get("/bin/tool")).toBe("3.1.4")

    let failedReads = 0
    const failing = makeVersionProber({
      readVersionOutput: () => {
        failedReads += 1
        return Promise.reject(new Error("no --version flag"))
      },
      identity: () => "a"
    })
    await expect(failing.probe(["/bin/broken"])).resolves.toBeUndefined()
    expect(failing.get("/bin/broken")).toBeUndefined()
    await failing.probe(["/bin/broken"])
    expect(failedReads).toBe(1)
  })

  it("notices a package-manager upgrade that keeps the binary's mtime", async () => {
    const root = mkdtempSync(join(tmpdir(), "version-probe-"))
    cleanups.push(() => rmSync(root, { force: true, recursive: true }))
    const stamped = new Date("1980-01-01T00:00:00Z")
    const release = (version: string) => {
      const path = join(root, version)
      writeFileSync(path, `tool ${version}`)
      utimesSync(path, stamped, stamped)
      return path
    }
    const link = join(root, "tool")
    symlinkSync(release("2.0.26"), link)
    const prober = makeVersionProber({
      readVersionOutput: (path) => Promise.resolve(readFileSync(path, "utf8"))
    })
    await prober.probe([link])
    expect(prober.get(link)).toBe("2.0.26")

    unlinkSync(link)
    symlinkSync(release("2.0.27"), link)
    await prober.probe([link])
    expect(prober.get(link)).toBe("2.0.27")
  })

  it("re-reads a launcher whose payload changed behind it only when forced", async () => {
    const root = mkdtempSync(join(tmpdir(), "version-probe-"))
    cleanups.push(() => rmSync(root, { force: true, recursive: true }))
    const active = join(root, ".active-version")
    const launcher = join(root, "tool")
    writeFileSync(active, "1.4.9\n")
    writeFileSync(launcher, `#!/bin/sh\necho "tool $(cat '${active}')"\n`)
    chmodSync(launcher, 0o755)
    const prober = makeVersionProber()
    await prober.probe([launcher])
    expect(prober.get(launcher)).toBe("1.4.9")

    writeFileSync(active, "1.4.10\n")
    await prober.probe([launcher])
    expect(prober.get(launcher)).toBe("1.4.9")

    await prober.probe([launcher], process.env, { force: true })
    expect(prober.get(launcher)).toBe("1.4.10")
  })

  it("does not let a forced probe reuse an in-flight read that started earlier", async () => {
    const releases: Array<(output: string) => void> = []
    const secondRead = Promise.withResolvers<void>()
    const prober = makeVersionProber({
      readVersionOutput: () =>
        new Promise((resolve) => {
          releases.push(resolve)
          if (releases.length === 2) secondRead.resolve()
        }),
      identity: () => "a"
    })
    const stale = prober.probe(["/bin/tool"])
    const forced = prober.probe(["/bin/tool"], {}, { force: true })
    expect(releases).toHaveLength(1)
    releases[0]?.("tool 1.0.0")
    await stale
    expect(prober.get("/bin/tool")).toBe("1.0.0")
    await secondRead.promise
    releases[1]?.("tool 2.0.0")
    await forced
    expect(prober.get("/bin/tool")).toBe("2.0.0")
  })

  it("keeps default probing best effort when stat encounters a symlink loop", async () => {
    const root = mkdtempSync(join(tmpdir(), "version-probe-"))
    cleanups.push(() => rmSync(root, { force: true, recursive: true }))
    const path = join(root, "loop")
    symlinkSync(path, path)
    expect(() => statSync(path)).toThrow(expect.objectContaining({ code: "ELOOP" }))
    const prober = makeVersionProber()
    await expect(prober.probe([path])).resolves.toBeUndefined()
    expect(prober.get(path)).toBeUndefined()
    expect(binaryIdentity(path)).toBeUndefined()
  })

  it("probes a real binary with the default runner and stat", async () => {
    const prober = makeVersionProber()
    await prober.probe(["/bin/bash", "/nonexistent-binary-for-test"])
    expect(prober.get("/bin/bash")).toMatch(/^\d+\.\d+/)
    expect(prober.get("/nonexistent-binary-for-test")).toBeUndefined()
  })
})

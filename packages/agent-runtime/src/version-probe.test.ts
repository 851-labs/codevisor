import { describe, expect, it } from "vitest"
import { makeVersionProber, parseVersionOutput } from "./version-probe.js"

describe("parseVersionOutput", () => {
  it("extracts the first semver-ish token", () => {
    expect(parseVersionOutput("claude 2.1.5 (Claude Code)")).toBe("2.1.5")
    expect(parseVersionOutput("codex-cli 0.48.0-alpha.2\n")).toBe("0.48.0-alpha.2")
    expect(parseVersionOutput("v1.2")).toBe("1.2")
    expect(parseVersionOutput("no version here")).toBeUndefined()
  })
})

describe("makeVersionProber", () => {
  it("caches by path + mtime and re-probes when the binary changes", async () => {
    let reads = 0
    let mtime = 100
    const prober = makeVersionProber({
      readVersionOutput: () => {
        reads += 1
        return Promise.resolve(`tool ${reads}.0.0`)
      },
      modifiedTime: () => mtime
    })

    expect(prober.get("/bin/tool")).toBeUndefined()
    await prober.probe(["/bin/tool"])
    expect(prober.get("/bin/tool")).toBe("1.0.0")

    // Unchanged binary: cache hit, no new spawn.
    await prober.probe(["/bin/tool", "/bin/tool"])
    expect(reads).toBe(1)

    // Upgraded in place: mtime moves, version refreshes.
    mtime = 200
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
      modifiedTime: () => 1
    })
    const first = prober.probe(["/bin/tool"])
    const second = prober.probe(["/bin/tool"])
    release?.()
    await Promise.all([first, second])
    expect(reads).toBe(1)
    expect(prober.get("/bin/tool")).toBe("3.1.4")

    const failing = makeVersionProber({
      readVersionOutput: () => Promise.reject(new Error("no --version flag")),
      modifiedTime: () => 1
    })
    await expect(failing.probe(["/bin/broken"])).resolves.toBeUndefined()
    expect(failing.get("/bin/broken")).toBeUndefined()
    // The failure is cached too — no retry storm for the same mtime.
    await failing.probe(["/bin/broken"])
  })

  it("probes a real binary with the default runner and stat", async () => {
    const prober = makeVersionProber()
    await prober.probe(["/bin/bash", "/nonexistent-binary-for-test"])
    expect(prober.get("/bin/bash")).toMatch(/^\d+\.\d+/)
    expect(prober.get("/nonexistent-binary-for-test")).toBeUndefined()
  })
})

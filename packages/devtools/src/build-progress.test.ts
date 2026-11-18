import { describe, expect, it, vi } from "vitest"

import { createBuildProgress, runWithProgress } from "./build-progress.ts"

describe("build progress", () => {
  it("counts crates instead of printing them and reports the current phase on each heartbeat", () => {
    const written: Array<string> = []
    let now = 0
    const progress = createBuildProgress(
      (line) => written.push(line),
      () => now
    )

    progress.line("==> Compiling for aarch64-apple-ios (3 of 5)")
    progress.line("  Downloaded tokio v1.50.0")
    progress.line("   Compiling tokio v1.50.0")
    progress.line("   Compiling iroh v1.2.0")
    progress.line("warning: unused variable")
    now = 95_000
    progress.heartbeat()
    progress.line("==> Assembling CodevisorNetFFI.xcframework")
    now = 100_000
    progress.heartbeat()

    expect(written).toEqual([
      "==> Compiling for aarch64-apple-ios (3 of 5)",
      "warning: unused variable",
      "    Compiling for aarch64-apple-ios (3 of 5): 2 crates so far, 1m 35s",
      "==> Assembling CodevisorNetFFI.xcframework",
      "    Assembling CodevisorNetFFI.xcframework: still working, 5s"
    ])
  })

  it("passes a build's remaining output through from both streams and fails when the build fails", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    const script = [
      'console.error("   Compiling tokio v1.50.0")',
      'console.error("error: could not compile")',
      'console.log("built nothing")',
      "process.exit(3)"
    ].join(";")

    await expect(
      runWithProgress(process.execPath, ["-e", script], {}, "Compiling the Node addon")
    ).rejects.toThrow(/failed \(code 3\)/)

    expect(log.mock.calls.map(([line]) => String(line)).toSorted()).toEqual([
      "==> Compiling the Node addon",
      "built nothing",
      "error: could not compile"
    ])
  })
})

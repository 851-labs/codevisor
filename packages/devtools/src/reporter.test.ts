import { describe, expect, it, vi } from "vitest"

import { createReporter, processOutput } from "./reporter.ts"

const capture = () => {
  const log: Array<string> = []
  const data: Array<string> = []
  return {
    log,
    data,
    output: { log: (line: string) => log.push(line), data: (line: string) => data.push(line) }
  }
}

describe("createReporter", () => {
  it("writes plain glyph lines to the log and results to data off a terminal", () => {
    const { log, data, output } = capture()
    const reporter = createReporter({}, output, false)

    reporter.step("Pushing")
    reporter.done("Landed")
    reporter.failure("Push failed")
    reporter.result("/path/to/thing")

    expect(log).toEqual(["▸ Pushing", "✓ Landed", "✗ Push failed"])
    expect(data).toEqual(["/path/to/thing"])
  })

  it("colors a terminal unless NO_COLOR is set", () => {
    const colored = capture()
    createReporter({}, colored.output, true).done("Landed")
    const plain = capture()
    createReporter({ NO_COLOR: "1" }, plain.output, true).done("Landed")

    expect(colored.log[0]).toContain("\u001B[32m✓")
    expect(plain.log).toEqual(["✓ Landed"])
  })

  it("turns failures into GitHub error annotations in Actions and keeps other lines plain", () => {
    const { log, data, output } = capture()
    const reporter = createReporter({ GITHUB_ACTIONS: "true", FORCE_COLOR: "1" }, output, true)

    reporter.step("Pushing")
    reporter.done("Landed")
    reporter.failure("100% broken\nsee log")
    reporter.result("value")

    expect(log).toEqual(["▸ Pushing", "✓ Landed", "::error::100%25 broken%0Asee log"])
    expect(data).toEqual(["value"])
  })

  it("sends logs to stderr and results to stdout by default", () => {
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true)
    const stdout = vi.spyOn(process.stdout, "write").mockImplementation(() => true)

    processOutput.log("a log line")
    processOutput.data("a result")

    expect(stderr).toHaveBeenCalledWith("a log line\n")
    expect(stdout).toHaveBeenCalledWith("a result\n")
  })
})

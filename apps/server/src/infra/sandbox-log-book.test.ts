import { describe, expect, it } from "vitest"

import { makeSandboxLogBook, SANDBOX_LOG_LINES, SANDBOX_LOGS_KEPT } from "./sandbox-log-book.js"

const line = (machineId: string, text: string) => ({
  machineId,
  stage: "install" as const,
  stream: "stdout" as const,
  line: text
})

describe("sandbox start logs", () => {
  it("keeps only the newest lines of each sandbox", async () => {
    const book = makeSandboxLogBook()
    book.start("box")
    const record = book.recording(undefined)

    for (let index = 0; index <= SANDBOX_LOG_LINES; index += 1)
      await record(line("box", `${index}`))

    const lines = book.lines("box")
    expect(lines).toHaveLength(SANDBOX_LOG_LINES)
    expect(lines[0]?.line).toBe("1")
  })

  it("forgets the oldest sandboxes' logs and ignores lines for sandboxes it isn't keeping", async () => {
    const book = makeSandboxLogBook()
    const record = book.recording(undefined)

    for (let index = 0; index <= SANDBOX_LOGS_KEPT; index += 1) book.start(`box-${index}`)
    await record(line("box-0", "late"))
    await record(line("box-1", "kept"))

    expect(book.lines("box-0")).toEqual([])
    expect(book.lines("box-1")).toEqual([line("box-1", "kept")])
  })

  it("starts a sandbox's log over when it starts again", async () => {
    const book = makeSandboxLogBook()
    const record = book.recording(undefined)
    book.start("box")
    await record(line("box", "first try"))

    book.start("box")

    expect(book.lines("box")).toEqual([])
  })
})

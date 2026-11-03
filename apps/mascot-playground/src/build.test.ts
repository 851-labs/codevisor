import { fileURLToPath } from "node:url"

import { build, type Rollup } from "vite"
import { describe, expect, it } from "vitest"

const appRoot = fileURLToPath(new URL("..", import.meta.url))

const outputFiles = (result: Awaited<ReturnType<typeof build>>): Rollup.OutputBundle[string][] =>
  [result].flat().flatMap((output) => ("output" in output ? output.output : []))

describe("mascot playground", () => {
  it("builds with the bot mascot bundled from its source", async () => {
    const result = await build({ root: appRoot, logLevel: "silent", build: { write: false } })
    const files = outputFiles(result)
    const code = files.map((file) => (file.type === "chunk" ? file.code : "")).join("")

    expect(files.map((file) => file.fileName)).toContain("index.html")
    expect(code).toContain("bot-mascot-svg")
  }, 60_000)
})

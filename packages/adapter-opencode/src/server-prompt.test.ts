import { describe, expect, it } from "vitest"

import type { Catalog } from "./catalog.js"
import { makeMessageIds, prepareSubmission } from "./server-prompt.js"

const catalog: Catalog = {
  models: [],
  defaultModel: { providerID: "p", id: "m" },
  modes: [],
  defaultModeID: "build",
  commands: ["review"],
  skills: { invocationPrefix: "/", skills: [{ name: "lint", invocation: "/lint" }] }
}

const attachment = (name: string, inline?: { mimeType: string; data: Buffer }) => ({
  name,
  mimeType: "image/png",
  kind: "image" as const,
  sizeBytes: 3,
  path: `/files/${name}`,
  ...(inline === undefined ? {} : { inline })
})

const readable = async () => true

describe("OpenCode prompt submission", () => {
  it("attaches readable files by path, inline data otherwise, and links the rest", async () => {
    const submission = await prepareSubmission(
      {
        text: "look",
        attachments: [
          attachment("a.png"),
          attachment("b.png", { mimeType: "image/png", data: Buffer.from("png") }),
          attachment("c.png")
        ]
      },
      catalog,
      async (path) => path === "/files/a.png"
    )
    expect(submission).toEqual({
      kind: "prompt",
      body: {
        text: "look\n[c.png](file:///files/c.png)",
        files: [
          { uri: "file:///files/a.png", name: "a.png" },
          { uri: "data:image/png;base64,cG5n", name: "b.png" }
        ]
      }
    })
  })

  it("routes slash commands, compaction and skills", async () => {
    expect(await prepareSubmission({ text: "/review  main " }, catalog, readable)).toEqual({
      kind: "command",
      body: { text: "main", name: "review" }
    })
    expect(await prepareSubmission({ text: "/compact" }, catalog, readable)).toEqual({
      kind: "compact"
    })
    expect(await prepareSubmission({ text: "/lint src" }, catalog, readable)).toEqual({
      kind: "prompt",
      body: { text: "/lint src", skills: [{ id: "lint" }] }
    })
    expect(await prepareSubmission({ text: "/ nothing" }, catalog, readable)).toEqual({
      kind: "prompt",
      body: { text: "/ nothing" }
    })
  })

  it("mints ascending OpenCode message ids", () => {
    const next = makeMessageIds()
    const first = next(1_000)
    const second = next(1_000)
    const third = next(2_000)
    expect(first).toMatch(/^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$/)
    expect([first, second, third].map((id) => id.slice(0, 16))).toEqual([
      "msg_0000003e8001",
      "msg_0000003e8002",
      "msg_0000007d0001"
    ])
  })
})

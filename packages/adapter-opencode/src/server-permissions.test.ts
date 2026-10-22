import { describe, expect, it } from "vitest"

import { permissionQuestion } from "./server-permissions.js"

const question = (
  action: string,
  metadata: Record<string, unknown>,
  extra: Record<string, unknown> = {}
) =>
  permissionQuestion(
    { id: "per_1", sessionID: "ses", action, metadata, ...extra },
    undefined,
    undefined
  ).question

describe("OpenCode permission questions", () => {
  it("names what each tool wants to touch", () => {
    expect(question("external_directory", { parentDir: "/etc" })).toBe("external_directory: /etc")
    expect(question("websearch", { query: "opencode" })).toBe("websearch: opencode")
    expect(question("glob", { pattern: "**/*.ts" })).toBe("glob: **/*.ts")
    expect(question("edit", { filePath: "src/a.ts" })).toBe("edit: src/a.ts")
    expect(question("bash", { cmd: "make" })).toBe("bash: make")
    expect(question("bash", { command: "make test", cmd: "make" })).toBe("bash: make test")
    expect(question("external_directory", { description: "Read logs", parentDir: "/var" })).toBe(
      "external_directory: Read logs"
    )
    expect(question("webfetch", { url: "https://opencode.ai" })).toBe(
      "webfetch: https://opencode.ai"
    )
    expect(question("grep", { pattern: "TODO" })).toBe("grep: TODO")
    expect(question("mcp_tool", {}, { message: "Use the browser" })).toBe(
      "mcp_tool: Use the browser"
    )
  })

  it("prefixes subagent requests with the subagent's title", () => {
    const child = { id: "ses_child", parentID: "ses", depth: 1, title: "Explore" }
    expect(
      permissionQuestion({ action: "read", metadata: { path: "a" } }, undefined, child).question
    ).toBe("Explore: read: a")
    expect(permissionQuestion({ action: "doom_loop" }, undefined, child).question).toBe("Explore")
  })
})

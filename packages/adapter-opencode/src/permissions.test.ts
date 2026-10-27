import { describe, expect, it } from "vitest"

import {
  OPENCODE_FULL_ACCESS_PERMISSIONS,
  OPENCODE_NATIVE_SUBAGENTS_OFF,
  withOpenCodePermissions
} from "./permissions.js"

const config = (env: NodeJS.ProcessEnv) => JSON.parse(env.OPENCODE_CONFIG_CONTENT!)
const launchPermissions = { ...OPENCODE_FULL_ACCESS_PERMISSIONS, ...OPENCODE_NATIVE_SUBAGENTS_OFF }

describe("OpenCode full-access permissions", () => {
  it("allows only what OpenCode would ask about", () => {
    const env = withOpenCodePermissions({ PATH: "/bin" })
    expect(env.PATH).toBe("/bin")
    expect(config(env)).toEqual({ permission: launchPermissions })
  })

  it("keeps the rest of the config OpenCode is already given", () => {
    const env = withOpenCodePermissions({
      OPENCODE_CONFIG_CONTENT: JSON.stringify({
        plugins: [{ package: "/p" }],
        permission: { bash: { "rm *": "deny" }, external_directory: "ask" }
      })
    })
    expect(config(env)).toEqual({
      plugins: [{ package: "/p" }],
      permission: { bash: { "rm *": "deny" }, ...launchPermissions }
    })
  })

  it("turns off OpenCode's native subagent tool even when the config allows it", () => {
    for (const task of ["allow", { explore: "allow" }]) {
      const content = JSON.stringify({ permission: { task } })
      const env = withOpenCodePermissions({ OPENCODE_CONFIG_CONTENT: content })
      expect(config(env).permission.task).toBe("deny")
    }
  })

  it("denies Claude's browser and desktop skills when Codevisor's tools are attached", () => {
    const toolGateway = { bearerToken: "t", name: "codevisor", url: "http://127.0.0.1:1/mcp" }
    const denied = { "built-in-browser": "deny", "chrome-browser": "deny", "computer-use": "deny" }
    expect(config(withOpenCodePermissions({}, { toolGateway })).permission.skill).toEqual(denied)
    for (const [skill, kept] of [
      [{ review: "ask" }, { review: "ask" }],
      ["ask", { "*": "ask" }]
    ] as const) {
      const content = JSON.stringify({ permission: { skill } })
      const env = withOpenCodePermissions({ OPENCODE_CONFIG_CONTENT: content }, { toolGateway })
      expect(config(env).permission.skill).toEqual({ ...kept, ...denied })
    }
  })

  it("replaces config OpenCode would ignore", () => {
    for (const content of ["", "{not json", "[]", JSON.stringify({ permission: "ask" })])
      expect(
        config(withOpenCodePermissions({ OPENCODE_CONFIG_CONTENT: content })).permission
      ).toEqual(launchPermissions)
  })
})

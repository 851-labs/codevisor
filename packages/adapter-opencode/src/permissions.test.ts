import { describe, expect, it } from "vitest"

import { OPENCODE_FULL_ACCESS_PERMISSIONS, withOpenCodePermissions } from "./permissions.js"

const config = (env: NodeJS.ProcessEnv) => JSON.parse(env.OPENCODE_CONFIG_CONTENT!)

describe("OpenCode full-access permissions", () => {
  it("allows only what OpenCode would ask about", () => {
    const env = withOpenCodePermissions({ PATH: "/bin" })
    expect(env.PATH).toBe("/bin")
    expect(config(env)).toEqual({ permission: OPENCODE_FULL_ACCESS_PERMISSIONS })
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
      permission: { bash: { "rm *": "deny" }, ...OPENCODE_FULL_ACCESS_PERMISSIONS }
    })
  })

  it("replaces config OpenCode would ignore", () => {
    for (const content of ["", "{not json", "[]", JSON.stringify({ permission: "ask" })])
      expect(
        config(withOpenCodePermissions({ OPENCODE_CONFIG_CONTENT: content })).permission
      ).toEqual(OPENCODE_FULL_ACCESS_PERMISSIONS)
  })
})

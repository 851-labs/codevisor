import { harnessCatalog, type ProviderEnvironment } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import { makeOpenCodeProvider } from "./provider.js"

const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "opencode",
  locateExecutable: (name) => (name === "opencode" ? "/bin/opencode" : undefined)
}

describe("OpenCode provider", () => {
  it("owns the built-in OpenCode harness instead of routing it through generic ACP", () => {
    const definition = harnessCatalog.find((candidate) => candidate.id === "opencode")
    expect(definition?.provider).toBe("opencode")
    const provider = makeOpenCodeProvider(environment)
    expect(provider.id).toBe("opencode")
    expect(provider.readiness(definition!)).toEqual({ state: "ready" })
  })
})

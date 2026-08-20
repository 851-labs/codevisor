import { harnessCatalog, type ProviderEnvironment } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"
import { makeGrokBuildProvider } from "./provider.js"

const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "grok",
  locateExecutable: (name) => (name === "grok" ? "/bin/grok" : undefined)
}

describe("Grok Build provider", () => {
  it("owns the built-in Grok harness instead of routing it through generic ACP", () => {
    const definition = harnessCatalog.find((candidate) => candidate.id === "grok-build")
    expect(definition?.provider).toBe("grok-build")
    const provider = makeGrokBuildProvider(environment)
    expect(provider.id).toBe("grok-build")
    expect(provider.readiness(definition!)).toEqual({ state: "ready" })
  })
})

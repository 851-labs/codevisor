import { harnessCatalog, type ProviderEnvironment } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"
import { makeCursorProvider } from "./provider.js"

const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "cursor-agent",
  locateExecutable: (name) => (name === "cursor-agent" ? "/bin/cursor-agent" : undefined)
}

describe("Cursor provider", () => {
  it("owns the built-in Cursor harness instead of routing it through generic ACP", () => {
    const definition = harnessCatalog.find((candidate) => candidate.id === "cursor")
    expect(definition?.provider).toBe("cursor")
    expect(definition?.launch).toEqual({
      args: ["--force", "--sandbox", "disabled", "acp"],
      command: "cursor-agent",
      kind: "executable"
    })
    const provider = makeCursorProvider(environment)
    expect(provider.id).toBe("cursor")
    expect(provider.readiness(definition!)).toEqual({ state: "ready" })
  })
})

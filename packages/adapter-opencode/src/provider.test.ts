import type { AcpConnector } from "@codevisor/adapter-acp"
import {
  AgentRuntimeError,
  harnessCatalog,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"
import { Effect } from "effect"
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

  it("launches chats with OpenCode's full-access permissions on top of the account's config", async () => {
    const definition = harnessCatalog.find((candidate) => candidate.id === "opencode")!
    const launched: Array<NodeJS.ProcessEnv> = []
    const connector: AcpConnector = {
      connect: (request) => {
        launched.push(request.env)
        return Effect.fail(new AgentRuntimeError({ message: "stop", operation: "connect" }))
      }
    }
    const provider = makeOpenCodeProvider(environment, { connector })
    await Effect.runPromise(
      Effect.flip(
        provider.createSession(definition, "/project", async () => undefined, {
          id: "opencode-default",
          profileKind: "default",
          env: { OPENCODE_CONFIG_CONTENT: JSON.stringify({ model: "x/y" }) }
        })
      )
    )
    const config = JSON.parse(launched[0]!.OPENCODE_CONFIG_CONTENT!)
    expect(config).toMatchObject({ model: "x/y", permission: { external_directory: "allow" } })
    expect(launched[0]!.PATH).toBe("/bin")
  })
})

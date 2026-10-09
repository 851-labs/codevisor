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
    const provider = makeOpenCodeProvider(environment, { locateOpenCode: () => undefined })
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
    const provider = makeOpenCodeProvider(environment, {
      connector,
      locateOpenCode: () => undefined
    })
    await Effect.runPromise(
      Effect.flip(
        provider.createSession(
          definition,
          "/project",
          async () => undefined,
          {
            id: "opencode-default",
            profileKind: "default",
            env: { OPENCODE_CONFIG_CONTENT: JSON.stringify({ model: "x/y" }) }
          },
          { bearerToken: "t", name: "codevisor", url: "http://127.0.0.1:1/mcp" }
        )
      )
    )
    const config = JSON.parse(launched[0]!.OPENCODE_CONFIG_CONTENT!)
    expect(config).toMatchObject({
      model: "x/y",
      permission: { external_directory: "allow", skill: { "computer-use": "deny" } }
    })
    expect(launched[0]!.PATH).toBe("/bin")
  })

  it("runs the newest OpenCode, not whichever PATH lists first", async () => {
    const definition = harnessCatalog.find((candidate) => candidate.id === "opencode")!
    const commands: Array<string> = []
    const connector: AcpConnector = {
      connect: (request) => {
        commands.push(request.command)
        return Effect.fail(new AgentRuntimeError({ message: "stop", operation: "connect" }))
      }
    }
    const newest = makeOpenCodeProvider(environment, {
      connector,
      locateOpenCode: (env) => (env.PATH === "/bin" ? "/home/me/.opencode/bin/opencode" : undefined)
    })
    await Effect.runPromise(
      Effect.flip(newest.createSession(definition, "/p", async () => undefined))
    )
    expect(commands).toEqual(["/home/me/.opencode/bin/opencode"])
    // Other executables are found as before.
    expect(
      makeOpenCodeProvider(environment).readiness({ ...definition, detectBinaries: ["nope"] })
    ).toMatchObject({
      state: "unavailable"
    })
  })
})

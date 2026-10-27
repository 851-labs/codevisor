import type { AcpConnector } from "@codevisor/adapter-acp"
import {
  AgentRuntimeError,
  harnessCatalog,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeOpenCodeServerPool } from "./pool.js"
import { makeOpenCodeProvider } from "./provider.js"
import type { OpenCodeServerOptions } from "./server.js"
import { event, makeFakeServer, makeSink } from "./test-support.js"

const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  envFor: () => Promise.resolve(environment.env),
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
      locateOpenCode: () => undefined,
      majorVersion: async () => 1
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
      permission: {
        external_directory: "allow",
        task: "deny",
        skill: { "computer-use": "deny" }
      }
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
      locateOpenCode: (env) =>
        env.PATH === "/bin" ? "/home/me/.opencode/bin/opencode" : undefined,
      majorVersion: async () => undefined
    })
    await Effect.runPromise(
      Effect.flip(newest.createSession(definition, "/p", async () => undefined))
    )
    expect(commands).toEqual(["/home/me/.opencode/bin/opencode"])
    expect(
      makeOpenCodeProvider(environment).readiness({ ...definition, detectBinaries: ["nope"] })
    ).toMatchObject({
      state: "unavailable"
    })
  })

  it("runs OpenCode 2 chats on its server instead of `opencode acp`", async () => {
    const definition = harnessCatalog.find((candidate) => candidate.id === "opencode")!
    const fake = makeFakeServer((request) => {
      const responses: Record<string, unknown> = {
        "/api/plugin": { data: [{ id: "core" }] },
        "/api/model": { data: [{ id: "m1", providerID: "p" }] },
        "/api/model/default": { data: { providerID: "p", id: "m1" } },
        "/api/agent": { data: [{ id: "build" }] },
        "/api/command": { data: [] },
        "/api/skill": { data: [] },
        "/api/session/ses_old": { data: { id: "ses_old", location: { directory: "/project" } } },
        "/api/session?order=desc&limit=100": {
          data: [{ id: "ses_old", location: { directory: "/project" } }]
        }
      }
      if (request.path === "/api/session" && request.method === "POST")
        return { data: { id: "ses_new" } }
      return responses[request.path]
    })
    fake.queue.push(event("server.connected", {}))
    const starts: Array<OpenCodeServerOptions> = []
    const connect = vi.fn(() =>
      Effect.fail(new AgentRuntimeError({ message: "acp", operation: "connect" }))
    )
    const provider = makeOpenCodeProvider(environment, {
      connector: { connect },
      locateOpenCode: () => "/home/me/.opencode/bin/opencode",
      majorVersion: async (command) => (command === "/home/me/.opencode/bin/opencode" ? 2 : 1),
      server: {
        pool: makeOpenCodeServerPool({ schedule: () => () => undefined }),
        start: async (options) => {
          starts.push(options)
          return fake.server
        },
        readable: async () => true,
        wait: async () => undefined
      }
    })
    const sink = makeSink()
    const account = {
      id: "opencode-work",
      profileKind: "managed" as const,
      env: { XDG_DATA_HOME: "/profiles/work" },
      unsetEnv: ["PATH"]
    }
    const created = await Effect.runPromise(
      provider.createSession(definition, "/project", sink.emit, account)
    )
    expect(created.metadata.sessionId).toBe("ses_new")
    expect(connect).not.toHaveBeenCalled()
    expect(starts[0]?.command).toBe("/home/me/.opencode/bin/opencode")
    expect(starts[0]?.env.XDG_DATA_HOME).toBe("/profiles/work")
    expect(starts[0]?.env.PATH).toBeUndefined()
    expect(JSON.parse(starts[0]!.env.OPENCODE_CONFIG_CONTENT!)).toMatchObject({
      permission: { external_directory: "allow" }
    })
    await Effect.runPromise(created.handle.close)

    fake.queue.push(event("server.connected", {}))
    const loaded = await Effect.runPromise(
      provider.loadSession(definition, "ses_old", "/project", sink.emit, account)
    )
    expect(loaded.sessionId).toBe("ses_old")
    await Effect.runPromise(loaded.handle.close)
    expect(await provider.listAgentSessions!(definition, account)).toEqual([
      { sessionId: "ses_old", cwd: "/project" }
    ])
    expect(starts).toHaveLength(1)

    const offline = makeOpenCodeProvider(environment, {
      connector: { connect },
      locateOpenCode: () => "/home/me/.opencode/bin/opencode",
      majorVersion: async () => 2,
      server: { start: async () => Promise.reject(new Error("no server")) }
    })
    expect(await offline.listAgentSessions!(definition, account)).toEqual([])
    await expect(
      Effect.runPromise(offline.loadSession(definition, "ses_old", "/project", sink.emit))
    ).rejects.toThrow("no server")
  })

  it("keeps OpenCode 1 chats and session lists on `opencode acp`", async () => {
    const definition = harnessCatalog.find((candidate) => candidate.id === "opencode")!
    const commands: Array<string> = []
    const connector: AcpConnector = {
      connect: (request) => {
        commands.push(request.command)
        return Effect.fail(new AgentRuntimeError({ message: "stop", operation: "connect" }))
      }
    }
    const provider = makeOpenCodeProvider(environment, {
      connector,
      locateOpenCode: () => "/old/opencode",
      majorVersion: async () => 1
    })
    await Effect.runPromise(
      Effect.flip(provider.loadSession(definition, "s", "/p", async () => undefined))
    )
    expect(await provider.listAgentSessions!(definition)).toEqual([])
    expect(commands).toEqual(["/old/opencode", "/old/opencode"])
  })
})

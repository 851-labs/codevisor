import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AcpConnector } from "@codevisor/adapter-acp"
import {
  AgentRuntimeError,
  harnessCatalog,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeGrokBuildProvider } from "./provider.js"

const grokEnvironment = (env: NodeJS.ProcessEnv): ProviderEnvironment => ({
  env,
  envFor: () => Promise.resolve(env),
  executableExists: (name) => name === "grok",
  locateExecutable: (name) => (name === "grok" ? "/bin/grok" : undefined)
})

type LaunchRequest = Parameters<AcpConnector["connect"]>[0]

const launched = async (
  environment: ProviderEnvironment,
  toolGateway?: { bearerToken: string; name: string; url: string }
): Promise<LaunchRequest> => {
  const requests: Array<LaunchRequest> = []
  const connector: AcpConnector = {
    connect: (request) => {
      requests.push(request)
      return Effect.fail(new AgentRuntimeError({ message: "stop", operation: "connect" }))
    }
  }
  const definition = harnessCatalog.find((candidate) => candidate.id === "grok-build")!
  const provider = makeGrokBuildProvider(environment, { connector })
  await Effect.runPromise(
    Effect.flip(
      provider.createSession(definition, "/project", async () => undefined, undefined, toolGateway)
    )
  )
  return requests[0]!
}

describe("Grok Build provider", () => {
  it("launches Grok with its native subagents and workflows off, even when the user's env turns them on", async () => {
    const request = await launched(grokEnvironment({ GROK_SUBAGENTS: "1", GROK_WORKFLOWS: "1" }))
    expect(request.env).toMatchObject({ GROK_SUBAGENTS: "0", GROK_WORKFLOWS: "0" })
    expect(request.args).toContain("--no-leader")
  })

  it("launches Grok with its browser and desktop skills off when Codevisor's tools are attached", async () => {
    const grokHome = mkdtempSync(join(tmpdir(), "codevisor-grok-home-"))
    onTestFinished(() => rmSync(grokHome, { force: true, recursive: true }))
    const { env } = await launched(grokEnvironment({ GROK_HOME: grokHome, PATH: "/bin" }), {
      bearerToken: "t",
      name: "codevisor",
      url: "http://127.0.0.1:1/mcp"
    })
    expect(JSON.parse(env.GROK_CONFIG!)).toEqual({
      skills: { disabled: ["built-in-browser", "chrome-browser", "computer-use"] }
    })
    expect(env.PATH).toBe("/bin")
  })
})

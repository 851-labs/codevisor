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

describe("Grok Build provider", () => {
  it("launches Grok with its browser and desktop skills off when Codevisor's tools are attached", async () => {
    const grokHome = mkdtempSync(join(tmpdir(), "codevisor-grok-home-"))
    onTestFinished(() => rmSync(grokHome, { force: true, recursive: true }))
    const environment: ProviderEnvironment = {
      env: { GROK_HOME: grokHome, PATH: "/bin" },
      executableExists: (name) => name === "grok",
      locateExecutable: (name) => (name === "grok" ? "/bin/grok" : undefined)
    }
    const launched: Array<NodeJS.ProcessEnv> = []
    const connector: AcpConnector = {
      connect: (request) => {
        launched.push(request.env)
        return Effect.fail(new AgentRuntimeError({ message: "stop", operation: "connect" }))
      }
    }
    const definition = harnessCatalog.find((candidate) => candidate.id === "grok-build")!
    const provider = makeGrokBuildProvider(environment, { connector })
    await Effect.runPromise(
      Effect.flip(
        provider.createSession(definition, "/project", async () => undefined, undefined, {
          bearerToken: "t",
          name: "codevisor",
          url: "http://127.0.0.1:1/mcp"
        })
      )
    )
    expect(JSON.parse(launched[0]!.GROK_CONFIG!)).toEqual({
      skills: { disabled: ["built-in-browser", "chrome-browser", "computer-use"] }
    })
    expect(launched[0]!.PATH).toBe("/bin")
  })
})

import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeAgentRuntime } from "./index.js"
import type { AgentProvider } from "./types.js"

// Catalog knobs no shipped entry sets right now: pulling a broken
// integration (`disabledReason`) and launching an adapter through npx.
vi.mock("./harness-catalog.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./harness-catalog.js")>()
  return {
    ...actual,
    harnessCatalog: [
      {
        detectBinaries: ["paused-agent"],
        disabledReason: "Temporarily paused",
        id: "paused-agent",
        launch: { args: ["acp"], command: "paused-agent", kind: "executable" },
        name: "Paused Agent",
        provider: "acp",
        symbolName: "terminal"
      },
      {
        detectBinaries: ["npx-agent"],
        id: "npx-agent",
        launch: { args: [], kind: "npx", packageName: "npx-agent" },
        name: "npx Agent",
        provider: "acp",
        symbolName: "terminal"
      }
    ]
  }
})

const provider: AgentProvider = {
  id: "acp",
  readiness: () => ({ state: "ready" }),
  createSession: () => Effect.die("unused"),
  loadSession: () => Effect.die("unused")
}

describe("harness catalog knobs", () => {
  it("reports a pulled harness as unavailable and refuses its sessions", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      locateExecutable: () => undefined,
      providers: { acp: provider }
    })

    const harnesses = await Effect.runPromise(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "paused-agent")?.readiness).toEqual({
      detail: "Temporarily paused",
      state: "unavailable"
    })
    await expect(
      Effect.runPromise(runtime.createAgentSession("paused-agent", "/tmp/project", () => undefined))
    ).rejects.toThrow("Paused Agent is unavailable: Temporarily paused")
  })

  it("reports an npx-launched harness's launch kind", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      locateExecutable: () => undefined,
      providers: { acp: provider }
    })

    const harnesses = await Effect.runPromise(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "npx-agent")).toMatchObject({
      launchKind: "npx",
      readiness: { state: "ready" },
      source: "registry"
    })
  })
})

import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { HarnessDefinition } from "@codevisor/agent-runtime"
import type { CustomHarnessSpec } from "@codevisor/api"
import { afterEach, describe, expect, it } from "vitest"

import { makeAgents } from "../test-support-agents.js"
import { makeCustomHarnessStore, type CustomHarnessProbe } from "./custom-harness-store.js"

const roots: Array<string> = []

/// Each test gets its own root so the store never touches ~/.codevisor and
/// cases cannot observe one another's harnesses.json.
const makeRoot = async (): Promise<string> => {
  const root = await mkdtemp(join(tmpdir(), "custom-harness-store-"))
  roots.push(root)
  return root
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { force: true, recursive: true })))
})

/// Records catalog swaps that the shared fixture drops on the floor.
const recordingAgents = (): {
  readonly agents: ReturnType<typeof makeAgents>
  readonly extras: Array<ReadonlyArray<HarnessDefinition>>
} => {
  const base = makeAgents()
  const extras: Array<ReadonlyArray<HarnessDefinition>> = []
  return {
    agents: {
      ...base,
      setExtraHarnesses: (definitions) => extras.push([...definitions])
    },
    extras
  }
}

const spec: CustomHarnessSpec = { command: "my-agent", id: "mine", name: "Mine" }

describe("custom harness store", () => {
  it("lists specs from the resolved root", async () => {
    const root = await makeRoot()
    await writeFile(
      join(root, "harnesses.json"),
      JSON.stringify({ harnesses: [spec] }, null, 2),
      "utf8"
    )
    const { agents } = recordingAgents()

    const listed = await makeCustomHarnessStore(agents, () => root).list()

    expect(listed).toEqual([spec])
  })

  it("reports no specs when the file is absent", async () => {
    const root = await makeRoot()
    const { agents } = recordingAgents()

    expect(await makeCustomHarnessStore(agents, () => root).list()).toEqual([])
  })

  it("persists a replacement, swaps the catalog, and refreshes the environment", async () => {
    const root = await makeRoot()
    const { agents, extras } = recordingAgents()
    const store = makeCustomHarnessStore(agents, () => root)

    await store.replace([spec])

    expect(JSON.parse(await readFile(join(root, "harnesses.json"), "utf8"))).toEqual({
      harnesses: [spec]
    })
    expect(extras).toHaveLength(1)
    expect(extras[0]?.map((definition) => definition.id)).toEqual(["mine"])
    expect(agents.environmentRefreshes).toHaveLength(1)
    // The persisted file is the source of truth a later boot reads back.
    expect(await store.list()).toEqual([spec])
  })

  /// Records what the handshake boundary was asked to launch, and under which
  /// environment, without spawning anything.
  const recordingProbe = (): {
    readonly probe: CustomHarnessProbe
    readonly launches: Array<Parameters<CustomHarnessProbe["testAcpConnection"]>>
  } => {
    const launches: Array<Parameters<CustomHarnessProbe["testAcpConnection"]>> = []
    return {
      launches,
      probe: {
        resolveShellEnv: async () => ({ PATH: "/login-shell/bin" }),
        testAcpConnection: async (...call) => {
          launches.push(call)
          return { agentName: "Mine", ok: true, protocolVersion: 1 }
        }
      }
    }
  }

  it("probes a spec's launch under the login-shell environment", async () => {
    const root = await makeRoot()
    const { agents } = recordingAgents()
    const { probe, launches } = recordingProbe()
    const store = makeCustomHarnessStore(agents, () => root, probe)

    const result = await store.test({
      ...spec,
      args: ["--acp"],
      env: { MY_AGENT_TOKEN: "secret" }
    })

    expect(result).toEqual({ agentName: "Mine", ok: true, protocolVersion: 1 })
    expect(launches).toEqual([
      [
        { args: ["--acp"], command: "my-agent", env: { MY_AGENT_TOKEN: "secret" } },
        { env: { PATH: "/login-shell/bin" } }
      ]
    ])
  })

  it("probes a bare spec with no args and no env of its own", async () => {
    const root = await makeRoot()
    const { agents } = recordingAgents()
    const { probe, launches } = recordingProbe()

    await makeCustomHarnessStore(agents, () => root, probe).test(spec)

    expect(launches).toEqual([
      [{ args: [], command: "my-agent" }, { env: { PATH: "/login-shell/bin" } }]
    ])
  })
})

import type { Harness } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import { makeEventFanout, type CodevisorServerServices } from "../server-context.js"
import {
  jsonRequest,
  makeServices,
  pluginsStub,
  pluginSummary,
  run,
  skillsStub,
  startWithApp
} from "../test-support.js"
import { refreshSkillReadiness } from "./sync-readiness.js"

/// Phase 17: the mcp-readiness surface over HTTP — the on-demand publish
/// endpoint plus the reconcile pass keeping the machine's entry fresh.
describe("/v1/sync/mcp-readiness", () => {
  it("publishes this machine's MCP readiness on demand and after mcps reconciles", async () => {
    const { services } = await makeServices("server-readiness")
    const server = await startWithApp(services, undefined, { id: "server-readiness" })

    const published = await jsonRequest(server, "/v1/sync/mcp-readiness/publish", {
      method: "POST"
    })
    expect(published.status).toBe(200)
    expect(published.body).toEqual({ published: true })
    const document = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body as {
      entries: Array<{ key: string; value: { servers: Array<{ name: string; state: string }> } }>
    }
    expect(document.entries).toHaveLength(1)
    expect(document.entries[0]?.key).toBe("server-readiness")
    expect(document.entries[0]?.value.servers.length).toBeGreaterThan(0)

    // An mcps reconcile keeps readiness fresh as a side effect: a new
    // definition shows up in the machine's readiness entry.
    const created = await jsonRequest(server, "/v1/mcps", {
      body: JSON.stringify({
        name: "Fresh",
        transport: "http",
        url: "https://fresh.example/mcp",
        args: [],
        enabled: false,
        authType: "none"
      }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    await jsonRequest(server, "/v1/sync/mcps/reconcile", { method: "POST" })
    const after = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body as {
      entries: Array<{ value: { servers: Array<{ name: string; state: string }> } }>
    }
    expect(after.entries[0]?.value.servers.some((s) => s.name === "Fresh")).toBe(true)
  })

  it("enforces a per-machine disable overlay in the same request cycle", async () => {
    const { services } = await makeServices("server-overlay")
    const server = await startWithApp(services, undefined, { id: "server-overlay" })
    await jsonRequest(server, "/v1/sync/mcp-readiness/publish", { method: "POST" })

    // Disable a built-in on this machine via the generic overlay surface.
    const put = await jsonRequest(server, "/v1/sync/mcp-overlays", {
      body: JSON.stringify({
        entries: [
          {
            key: "enable|server-overlay|Computer Use",
            value: { enabled: false },
            timestamp: { wallMs: 10, counter: 0, deviceId: "phone" }
          }
        ]
      }),
      method: "PUT"
    })
    expect(put.status).toBe(200)

    // Readiness already reflects the enforced suppression...
    const document = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body as {
      entries: Array<{
        value: { servers: Array<{ name: string; state: string; reason?: string }> }
      }>
    }
    const computer = document.entries[0]?.value.servers.find((s) => s.name === "Computer Use")
    expect(computer).toMatchObject({ state: "disabled", reason: "Disabled on this machine" })
    // ...and sessions on this machine no longer resolve the server.
    const resolved = await services.mcp?.resolved()
    expect(resolved?.some((s) => s.name === "Computer Use")).toBe(false)
  })
})

/// Phase 24: the harness-readiness surface — the reported half of the
/// desired-vs-reported matrix, published on demand and after harness passes.
describe("/v1/sync/harness-readiness", () => {
  it("publishes this machine's harness readiness on demand", async () => {
    const { services } = await makeServices("server-hr")
    const server = await startWithApp(services, undefined, { id: "server-hr" })

    const published = await jsonRequest(server, "/v1/sync/harness-readiness/publish", {
      method: "POST"
    })
    expect(published.status).toBe(200)
    expect(published.body).toEqual({ published: true })

    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body as {
      entries: Array<{ key: string; value: { harnesses: Array<{ id: string; state: string }> } }>
    }
    expect(document.entries).toHaveLength(1)
    expect(document.entries[0]?.key).toBe("server-hr")
    const rows = document.entries[0]?.value.harnesses ?? []
    expect(rows.length).toBeGreaterThan(0)
    for (const row of rows) {
      expect(["ready", "signInRequired", "notInstalled", "disabled"]).toContain(row.state)
    }
  })

  it("applies global uninstalls and reports their lifecycle state", async () => {
    for (const available of [false, true]) {
      const { services } = await makeServices(`uninstall-${available}`)
      await run(
        services.db.mergeSyncEntries("harnesses", [
          {
            key: "codex",
            value: { enabled: false, installed: false, uninstall: true },
            timestamp: { wallMs: 1, counter: 0, deviceId: "test" }
          }
        ])
      )
      let started = false
      const lifecycle = {
        subscribe: () => () => {},
        onGateReleased: () => () => {},
        decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
        beginUninstall: async () => {
          started = true
          return { terminalId: "remove" }
        }
      } as unknown as NonNullable<CodevisorServerServices["lifecycle"]>
      const server = await startWithApp({ ...services, ...(available ? { lifecycle } : {}) })
      const result = await jsonRequest(server, "/v1/sync/harnesses/reconcile", { method: "POST" })
      expect(started).toBe(available)
      expect(result.body).toMatchObject({
        blocked: available ? [] : [{ id: "codex", reason: "Uninstall unavailable on this machine" }]
      })
    }
  })

  it("reports operation progress, errors, and machine overrides", async () => {
    const { services } = await makeServices("operation-report")
    const lifecycle = {
      subscribe: () => () => {},
      onGateReleased: () => () => {},
      decorateHarnesses: async (list: ReadonlyArray<Harness>) =>
        ["installing", "uninstalling", "failed"].flatMap((phase) => [
          {
            ...list[0]!,
            id: phase,
            lifecycle: {
              phase,
              ...(phase === "failed" ? { error: "Package manager unavailable" } : {})
            }
          },
          { ...list[0]!, id: `${phase}-empty`, lifecycle: { phase } }
        ])
    } as unknown as NonNullable<CodevisorServerServices["lifecycle"]>
    const server = await startWithApp({ ...services, lifecycle }, undefined, {
      id: "operation-report"
    })
    await jsonRequest(server, "/v1/sync/harness-readiness/publish", { method: "POST" })
    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body as {
      entries: Array<{
        value: { harnesses: Array<{ id: string; state: string; reason?: string }> }
      }>
    }
    const rows = document.entries[0]!.value.harnesses
    expect(rows.find((row) => row.id === "uninstalling")?.state).toBe("uninstalling")
    expect(rows.find((row) => row.id === "installing")?.state).toBe("installing")
    expect(rows.find((row) => row.id === "failed")).toMatchObject({
      state: "blocked",
      reason: "Package manager unavailable"
    })
    expect(rows.find((row) => row.id === "failed-empty")).toMatchObject({ state: "blocked" })
  })

  it("reports sign-in-required for installed-but-unauthenticated harnesses", async () => {
    const { services } = await makeServices("server-hr2")
    const auth = {
      // One installed harness awaiting sign-in, and one legacy-shaped row
      // with no desiredEnabled field (the ?? fallback reads enabled).
      decorateHarnesses: (list: ReadonlyArray<Harness>) =>
        Promise.resolve([
          ...list.map((harness) => ({
            ...harness,
            desiredEnabled: true,
            enabled: false,
            readiness: { state: "ready" },
            auth: { state: "unauthenticated" }
          })),
          ...list.map((harness) => {
            const { desiredEnabled: _omitted, ...rest } = harness as Harness & {
              desiredEnabled?: boolean
            }
            return {
              ...rest,
              id: "legacy-shape",
              enabled: true,
              readiness: { state: "ready" },
              auth: { state: "authenticated" }
            }
          }),
          // A desired harness the machine hasn't installed, with the
          // scanner's explanation riding along as the row's reason.
          ...list.map((harness) => ({
            ...harness,
            id: "missing-cli",
            desiredEnabled: true,
            enabled: false,
            readiness: { state: "notInstalled", detail: "CLI not found on PATH" }
          }))
        ]),
      decorateHarnessesFromStoredState: (list: ReadonlyArray<Harness>) =>
        auth.decorateHarnesses(list),
      activeAccountContext: () => Promise.resolve(undefined),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const server = await startWithApp({ ...services, auth }, undefined, { id: "server-hr2" })

    await jsonRequest(server, "/v1/sync/harness-readiness/publish", { method: "POST" })
    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body as {
      entries: Array<{ value: { harnesses: Array<{ id: string; state: string }> } }>
    }
    const rows = document.entries[0]?.value.harnesses ?? []
    expect(rows.some((row) => row.state === "signInRequired")).toBe(true)
    expect(rows.find((row) => row.id === "legacy-shape")?.state).toBe("ready")
    const missing = rows.find((row) => row.id === "missing-cli") as
      | { state: string; reason?: string }
      | undefined
    expect(missing?.state).toBe("notInstalled")
    expect(missing?.reason).toBe("CLI not found on PATH")
  })
})

/// Phase 24: the plugin-readiness surface — third readiness plane.
describe("/v1/sync/plugin-readiness", () => {
  it("publishes this machine's plugin readiness on demand", async () => {
    const { services } = await makeServices("server-plr")
    const server = await startWithApp({ ...services, plugins: pluginsStub([]) }, undefined, {
      id: "server-plr"
    })

    const published = await jsonRequest(server, "/v1/sync/plugin-readiness/publish", {
      method: "POST"
    })
    expect(published.status).toBe(200)
    expect(published.body).toEqual({ published: true })

    const document = (await jsonRequest(server, "/v1/sync/plugin-readiness")).body as {
      entries: Array<{ key: string; value: { plugins: Array<{ id: string; state: string }> } }>
    }
    expect(document.entries).toHaveLength(1)
    expect(document.entries[0]?.key).toBe("server-plr")
    // The stub's one plugin is linked — machine-only by definition.
    expect(document.entries[0]?.value.plugins).toEqual([
      { id: "owner.example", state: "machineOnly" }
    ])
  })

  it("reports an enabled plugin whose process died as blocked", async () => {
    const { services } = await makeServices("server-plr-failed")
    const plugins = {
      ...pluginsStub([]),
      list: async () => ({
        plugins: [
          { ...pluginSummary, state: "failed" as const },
          // A disabled plugin in the failed state is not a live failure.
          { ...pluginSummary, id: "owner.off", enabled: false, state: "failed" as const }
        ]
      })
    } as unknown as NonNullable<CodevisorServerServices["plugins"]>
    const server = await startWithApp({ ...services, plugins }, undefined, {
      id: "server-plr-failed"
    })

    await jsonRequest(server, "/v1/sync/plugin-readiness/publish", { method: "POST" })
    const entries = await run(services.db.getSyncEntries("plugin-readiness"))
    expect(entries[0]?.value).toEqual({
      plugins: [
        {
          id: "owner.example",
          state: "blocked",
          reason: "The plugin stopped running on this machine. Restart it to try again."
        },
        { id: "owner.off", state: "machineOnly" }
      ]
    })
  })
})

/// The skill-readiness surface — the reported half of the skills plane.
describe("/v1/sync/skill-readiness", () => {
  it("publishes this machine's skill readiness on demand and announces the change", async () => {
    const { services } = await makeServices("server-skr")
    await run(
      services.db.mergeSyncEntries("skills", [
        {
          key: "vnc-change",
          value: { hash: "b", name: "vnc-change" },
          timestamp: { wallMs: 1, counter: 0, deviceId: "elsewhere" }
        }
      ])
    )
    const fanout = await run(makeEventFanout)
    const announced = Promise.withResolvers<unknown>()
    const unsubscribe = fanout.subscribe((event) => {
      if (event.kind === "sync.changed" && event.subjectId === "skill-readiness") {
        announced.resolve(event.payload)
      }
    })
    const server = await startWithApp(
      {
        ...services,
        skills: skillsStub([]) as unknown as NonNullable<CodevisorServerServices["skills"]>
      },
      fanout,
      { id: "server-skr" }
    )

    const published = await jsonRequest(server, "/v1/sync/skill-readiness/publish", {
      method: "POST"
    })
    expect(published.status).toBe(200)
    expect(published.body).toEqual({ published: true })

    // The local skill was never published to the fleet; the fleet skill
    // has not arrived and, with no pass to explain it, carries no reason.
    const expected = {
      skills: [
        { directoryName: "deploy", state: "machineOnly" },
        { directoryName: "vnc-change", state: "awaitingContent" }
      ]
    }
    const entries = await run(services.db.getSyncEntries("skill-readiness"))
    expect(entries.map((entry) => entry.key)).toEqual(["server-skr"])
    expect(entries[0]?.value).toEqual(expected)
    expect(await announced.promise).toMatchObject({
      namespace: "skill-readiness",
      entries: [{ key: "server-skr", value: expected }]
    })
    unsubscribe()
  })
})

describe("refreshSkillReadiness", () => {
  it("skips machines without a skills manager and swallows scan failures", async () => {
    const fanout = await run(makeEventFanout)
    const { services } = await makeServices("server-skr-edge")
    const config = { id: "server-skr-edge" } as Parameters<typeof refreshSkillReadiness>[1]

    // The test host has no skills manager: nothing to derive or publish.
    expect("skills" in services).toBe(false)
    await refreshSkillReadiness(services, config, fanout)
    expect(await run(services.db.getSyncEntries("skill-readiness"))).toEqual([])

    // A failing scan never breaks the pass that triggered the refresh.
    const poisoned = {
      ...services,
      skills: { list: () => Promise.reject(new Error("boom")) }
    } as unknown as CodevisorServerServices
    await expect(refreshSkillReadiness(poisoned, config, fanout)).resolves.toBeUndefined()
    expect(await run(services.db.getSyncEntries("skill-readiness"))).toEqual([])
  })
})

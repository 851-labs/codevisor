import type { Harness } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import { waitFor } from "../changes-test-support.js"
import { defaultServerConfig } from "../server-config.js"
import { makeEventFanout, type CodevisorServerConfig } from "../server-context.js"
import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import {
  authStatus,
  fakeHarnessAuth,
  fakeHarnessLifecycle,
  rowWithId,
  syncRows
} from "./harness-auth-test-support.js"
import { field, itemsOf } from "./response-test-support.js"
import { refreshHarnessReadiness, refreshMcpReadiness } from "./sync-readiness.js"

const machine = (id: string): CodevisorServerConfig =>
  defaultServerConfig({ bootId: "test-boot", id })

const decorateSignInHarnesses: HarnessAuthManager["decorateHarnesses"] = (list) =>
  Promise.resolve([
    ...list.map((harness) => ({
      ...harness,
      desiredEnabled: true,
      enabled: false,
      readiness: { state: "ready" as const, version: "2.0.24" },
      auth: authStatus("unauthenticated")
    })),
    ...list.map((harness): Harness => {
      const { desiredEnabled: _omitted, ...rest } = harness
      return {
        ...rest,
        id: "legacy-shape",
        enabled: true,
        readiness: { state: "ready" },
        auth: authStatus("authenticated")
      }
    }),
    ...list.map((harness) => ({
      ...harness,
      id: "missing-cli",
      desiredEnabled: true,
      enabled: false,
      readiness: {
        state: "unavailable" as const,
        detail: "CLI not found on PATH",
        version: "1.0.0"
      }
    })),
    ...list.map((harness) => ({
      ...harness,
      id: "auth-error",
      desiredEnabled: true,
      enabled: true,
      readiness: { state: "ready" as const },
      auth: authStatus("error", "Keychain is locked")
    })),
    ...list.map((harness) => ({
      ...harness,
      id: "auth-free",
      desiredEnabled: true,
      enabled: true,
      readiness: { state: "ready" as const },
      auth: authStatus("notRequired")
    }))
  ])

describe("/v1/sync/mcp-readiness", () => {
  it("publishes this machine's MCP readiness and refreshes it after mcps reconciles", async () => {
    const { services } = await makeServices("server-readiness")
    const server = await startWithApp(services, undefined, { id: "server-readiness" })

    await refreshMcpReadiness(services, machine("server-readiness"), await run(makeEventFanout))
    const document = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body
    const entries = itemsOf(field(document, "entries"))
    expect(entries).toHaveLength(1)
    expect(field(entries[0], "key")).toBe("server-readiness")
    expect(syncRows(document, "servers").length).toBeGreaterThan(0)

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
    const after = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body
    expect(syncRows(after, "servers").some((row) => field(row, "name") === "Fresh")).toBe(true)
  })

  it("enforces a per-machine disable overlay in the same request cycle", async () => {
    const { services } = await makeServices("server-overlay")
    const server = await startWithApp(services, undefined, { id: "server-overlay" })
    await refreshMcpReadiness(services, machine("server-overlay"), await run(makeEventFanout))

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

    const document = (await jsonRequest(server, "/v1/sync/mcp-readiness")).body
    const computer = syncRows(document, "servers").find(
      (row) => field(row, "name") === "Computer Use"
    )
    expect(computer).toMatchObject({ state: "disabled", reason: "Disabled on this machine" })
    const resolved = await services.mcp?.resolved()
    expect(resolved?.some((s) => s.name === "Computer Use")).toBe(false)
  })
  it("republishes readiness when a server's state changes outside any sync request", async () => {
    const { services } = await makeServices("server-live")
    await startWithApp(services, undefined, { id: "server-live" })
    const created = await services.mcp.create({
      name: "Sentry",
      transport: "http",
      url: "https://sentry.example/mcp",
      args: [],
      enabled: false,
      authType: "none"
    })
    const readinessNames = async (): Promise<ReadonlyArray<unknown>> =>
      (await run(services.db.getSyncEntries("mcp-readiness")))
        .flatMap((entry) => itemsOf(field(entry.value, "servers")))
        .map((row) => field(row, "name"))

    await refreshMcpReadiness(services, machine("server-live"), await run(makeEventFanout))
    expect(await readinessNames()).toContain("Sentry")

    await services.mcp.update(created.id, { name: "Sentry Cloud" })

    await waitFor(async () => (await readinessNames()).includes("Sentry Cloud"))
    expect(await readinessNames()).not.toContain("Sentry")
  })
})

describe("/v1/sync/harness-readiness", () => {
  it("publishes this machine's harness readiness", async () => {
    const { services } = await makeServices("server-hr")
    const server = await startWithApp(services, undefined, { id: "server-hr" })

    await refreshHarnessReadiness(services, machine("server-hr"), await run(makeEventFanout))

    const document = (await jsonRequest(server, "/v1/sync/harness-readiness")).body
    const entries = itemsOf(field(document, "entries"))
    expect(entries).toHaveLength(1)
    expect(field(entries[0], "key")).toBe("server-hr")
    const rows = syncRows(document, "harnesses")
    expect(rows.length).toBeGreaterThan(0)
    for (const row of rows) {
      expect(["ready", "signInRequired", "notInstalled", "disabled"]).toContain(field(row, "state"))
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
      const lifecycle = fakeHarnessLifecycle({
        subscribe: () => () => {},
        onGateReleased: () => () => {},
        decorateHarnesses: async (list) => list,
        beginUninstall: async () => {
          started = true
        }
      })
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
    const lifecycle = fakeHarnessLifecycle({
      subscribe: () => () => {},
      onGateReleased: () => () => {},
      decorateHarnesses: async (list) =>
        (["installing", "uninstalling", "failed"] as const).flatMap((phase) => [
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
    })
    const server = await startWithApp({ ...services, lifecycle }, undefined, {
      id: "operation-report"
    })
    await refreshHarnessReadiness(
      { ...services, lifecycle },
      machine("operation-report"),
      await run(makeEventFanout)
    )
    const rows = syncRows(
      (await jsonRequest(server, "/v1/sync/harness-readiness")).body,
      "harnesses"
    )
    expect(field(rowWithId(rows, "uninstalling"), "state")).toBe("uninstalling")
    expect(field(rowWithId(rows, "installing"), "state")).toBe("installing")
    expect(rowWithId(rows, "failed")).toMatchObject({
      state: "blocked",
      reason: "Package manager unavailable"
    })
    expect(rowWithId(rows, "failed-empty")).toMatchObject({ state: "blocked" })
  })

  it("reports sign-in-required for installed-but-unauthenticated harnesses", async () => {
    const { services } = await makeServices("server-hr2")
    const auth = fakeHarnessAuth({
      decorateHarnesses: decorateSignInHarnesses,
      decorateHarnessesFromStoredState: (list) => decorateSignInHarnesses(list),
      activeAccountContext: () => Promise.resolve(undefined),
      subscribe: () => () => undefined
    })
    const server = await startWithApp({ ...services, auth }, undefined, { id: "server-hr2" })

    await refreshHarnessReadiness(
      { ...services, auth },
      machine("server-hr2"),
      await run(makeEventFanout)
    )
    const rows = syncRows(
      (await jsonRequest(server, "/v1/sync/harness-readiness")).body,
      "harnesses"
    )
    expect(
      rows
        .filter((row) => field(row, "state") === "signInRequired")
        .map((row) => field(row, "version"))
    ).toContain("2.0.24")
    expect(field(rowWithId(rows, "legacy-shape"), "state")).toBe("ready")
    const missing = rowWithId(rows, "missing-cli")
    expect(field(missing, "state")).toBe("notInstalled")
    expect(field(missing, "reason")).toBe("CLI not found on PATH")
    expect(missing).not.toHaveProperty("version")
    expect(rowWithId(rows, "auth-error")).toMatchObject({
      state: "signInRequired",
      reason: "Keychain is locked",
      authRequired: true
    })
    expect(rowWithId(rows, "auth-free")).toEqual({
      id: "auth-free",
      name: "Codex",
      symbolName: "chevron.left.forwardslash.chevron.right",
      state: "ready",
      installed: true,
      authRequired: false
    })
  })
})

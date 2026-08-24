import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { defaultServerConfig, startCodevisorServer } from "./server.js"
import {
  jsonRequest,
  makeServices,
  readWebSocketEvents,
  run,
  runningServers,
  tempDirs,
  waitFor
} from "./test-support.js"

describe("@codevisor/server self-updates", () => {
  it("reports and applies updates through the configured updater", async () => {
    const { services } = await makeServices("server-updates")

    // Servers without an updater refuse remote update requests.
    const plain = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-plain", port: 0 }))
    )
    runningServers.push(plain)
    expect((await jsonRequest(plain, "/v1/update/apply", { method: "POST" })).status).toBe(409)

    // Servers with an updater report fresh update state and apply on request.
    const updaterState = {
      available: true,
      applyCalls: 0,
      applyFails: false,
      forcedChecks: 0,
      appliedChannels: [] as Array<string>,
      checkedChannels: [] as Array<string>
    }
    const updatable = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          id: "server-updatable",
          port: 0,
          updater: {
            apply: async (options?: { readonly channel?: "stable" | "alpha" }) => {
              updaterState.appliedChannels.push(options?.channel ?? "stable")
              updaterState.applyCalls += 1
              if (updaterState.applyFails) {
                throw new Error("apply failed")
              }
            },
            check: async (options?: {
              readonly force?: boolean
              readonly channel?: "stable" | "alpha"
            }) => {
              if (options?.force === true) {
                updaterState.forcedChecks += 1
              }
              updaterState.checkedChannels.push(options?.channel ?? "stable")
              return {
                channel: options?.channel ?? "stable",
                checkedAt: "2026-06-30T00:00:00.000Z",
                currentVersion: "0.1.0",
                currentBuildNumber: 100,
                latestVersion: updaterState.available ? "0.2.0" : "0.1.0",
                latestBuildNumber: updaterState.available ? 200 : 100,
                migrationState: "idle" as const,
                updateAvailable: updaterState.available
              }
            }
          }
        })
      )
    )
    runningServers.push(updatable)

    expect((await jsonRequest(updatable, "/v1/update")).body).toMatchObject({
      channel: "stable",
      latestVersion: "0.2.0",
      updateAvailable: true,
      // Build numbers pass through untouched: clients rely on them to
      // confirm an update landed when version strings differ across feeds.
      currentBuildNumber: 100,
      latestBuildNumber: 200
    })
    // A plain check may serve the updater's cache; refresh=1 must not.
    expect(updaterState.forcedChecks).toBe(0)
    expect((await jsonRequest(updatable, "/v1/update?refresh=1")).body).toMatchObject({
      latestVersion: "0.2.0",
      updateAvailable: true
    })
    expect(updaterState.forcedChecks).toBe(1)
    // The client forwards its alpha preference; unknown channels are stable.
    expect((await jsonRequest(updatable, "/v1/update?channel=alpha")).body).toMatchObject({
      channel: "alpha"
    })
    expect((await jsonRequest(updatable, "/v1/update?channel=nightly")).body).toMatchObject({
      channel: "stable"
    })
    const applied = await jsonRequest(updatable, "/v1/update/apply?channel=alpha", {
      method: "POST"
    })
    expect(applied.status).toBe(202)
    expect(applied.body).toMatchObject({
      accepted: true,
      targetVersion: "0.2.0",
      targetBuildNumber: 200
    })
    // Applying always re-checks with force so the restart decision is live,
    // and installs from the same channel it checked.
    expect(updaterState.forcedChecks).toBe(2)
    await waitFor(() => updaterState.applyCalls === 1)
    expect(updaterState.checkedChannels.at(-1)).toBe("alpha")
    expect(updaterState.appliedChannels).toEqual(["alpha"])

    // A failing apply is swallowed after the 202 acknowledgement.
    updaterState.applyFails = true
    expect((await jsonRequest(updatable, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    await waitFor(() => updaterState.applyCalls === 2)

    // Nothing to apply when already up to date.
    updaterState.available = false
    const upToDate = await jsonRequest(updatable, "/v1/update/apply", { method: "POST" })
    expect(upToDate.status).toBe(200)
    expect(upToDate.body).toMatchObject({ accepted: false, targetVersion: "0.1.0" })
    expect(updaterState.applyCalls).toBe(2)
  })

  it("publishes update.changed only when the release state changes", async () => {
    const { services } = await makeServices("server-update-events")
    const state = { available: true }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          id: "server-update-events",
          port: 0,
          updater: {
            apply: async () => undefined,
            check: async () => ({
              channel: "stable",
              // Varies every check; the change fingerprint must ignore it.
              checkedAt: new Date().toISOString(),
              currentVersion: "0.1.0",
              latestVersion: state.available ? "0.2.0" : "0.1.0",
              migrationState: "idle" as const,
              updateAvailable: state.available
            })
          }
        })
      )
    )
    runningServers.push(server)

    await jsonRequest(server, "/v1/update?refresh=1")
    // An identical outcome stays silent…
    await jsonRequest(server, "/v1/update?refresh=1")
    // …while a changed one publishes again.
    state.available = false
    await jsonRequest(server, "/v1/update?refresh=1")

    const events = (await readWebSocketEvents(server, 2, 0)) as Array<{
      readonly kind: string
      readonly payload: { readonly latestVersion?: string; readonly updateAvailable?: boolean }
    }>
    expect(events.map((event) => event.kind)).toEqual(["update.changed", "update.changed"])
    expect(events[0]?.payload).toMatchObject({ latestVersion: "0.2.0", updateAvailable: true })
    expect(events[1]?.payload).toMatchObject({ latestVersion: "0.1.0", updateAvailable: false })
  })

  it("refuses to apply an update while a chat is mid-turn", async () => {
    const { agents, services } = await makeServices("server-busy")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          id: "server-busy",
          port: 0,
          updater: {
            apply: async () => undefined,
            check: async () => ({
              channel: "stable",
              checkedAt: "2026-06-30T00:00:00.000Z",
              currentVersion: "0.1.0",
              latestVersion: "0.2.0",
              migrationState: "idle" as const,
              updateAvailable: true
            })
          }
        })
      )
    )
    runningServers.push(server)

    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-busy-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
    mkdirSync(workspaceFolder)
    const workspace = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "Busy" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    // "slow prompt" keeps the session in activePromptSessions for ~250ms; the
    // update must be refused for that whole window.
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "slow prompt" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.length === 1)

    const busy = await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    expect(busy.status).toBe(200)
    expect(busy.body).toMatchObject({ accepted: false, reason: "busy" })

    // Once the turn finishes the update goes through again.
    await waitFor(async () => {
      const applied = await jsonRequest(server, "/v1/update/apply", { method: "POST" })
      return applied.status === 202
    })
  })
})

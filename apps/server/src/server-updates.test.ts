import { describe, expect, it } from "vitest"

import { observableFixture } from "./changes-test-support.js"
import { defaultServerConfig, startCodevisorServer } from "./server.js"
import {
  jsonRequest,
  makeServices,
  readWebSocketEvents,
  run,
  runningServers,
  waitFor
} from "./test-support.js"
import { field } from "./unknown-values.js"

describe("@codevisor/server self-updates", () => {
  it("reports and applies updates through the configured updater", async () => {
    const { services } = await makeServices("server-updates")

    const plain = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-plain", port: 0 })
      )
    )
    runningServers.push(plain)
    const plainApply = await jsonRequest(plain, "/v1/update/apply", { method: "POST" })
    expect([plainApply.status, plainApply.body]).toEqual([
      409,
      { error: "This server does not support remote updates" }
    ])

    const updaterState = observableFixture({
      available: true,
      applyCalls: 0,
      applyFails: false,
      forcedChecks: 0,
      appliedChannels: [] as Array<string>,
      checkedChannels: [] as Array<string>
    })
    const updatable = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          bootId: "test-boot",
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
      currentBuildNumber: 100,
      latestBuildNumber: 200
    })
    expect(updaterState.forcedChecks).toBe(0)
    expect((await jsonRequest(updatable, "/v1/update?refresh=1")).body).toMatchObject({
      latestVersion: "0.2.0",
      updateAvailable: true
    })
    expect(updaterState.forcedChecks).toBe(1)
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
    expect(updaterState.forcedChecks).toBe(2)
    await waitFor(() => updaterState.applyCalls === 1)
    expect(updaterState.checkedChannels.at(-1)).toBe("alpha")
    expect(updaterState.appliedChannels).toEqual(["alpha"])

    updaterState.applyFails = true
    expect((await jsonRequest(updatable, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    await waitFor(() => updaterState.applyCalls === 2)

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
          bootId: "test-boot",
          id: "server-update-events",
          port: 0,
          updater: {
            apply: async () => undefined,
            check: async () => ({
              channel: "stable",
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
    await jsonRequest(server, "/v1/update?refresh=1")
    state.available = false
    await jsonRequest(server, "/v1/update?refresh=1")

    const events = await readWebSocketEvents(server, 2, 0)
    expect(events.map((event) => field(event, "kind"))).toEqual([
      "update.changed",
      "update.changed"
    ])
    expect(field(events[0], "payload")).toMatchObject({
      latestVersion: "0.2.0",
      updateAvailable: true
    })
    expect(field(events[1], "payload")).toMatchObject({
      latestVersion: "0.1.0",
      updateAvailable: false
    })
  })

  it("answers a failed update check with a server error", async () => {
    const { services } = await makeServices("server-update-check-fails")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          bootId: "test-boot",
          id: "server-update-check-fails",
          port: 0,
          updater: {
            apply: async () => undefined,
            check: async () => {
              throw new Error("release feed unreachable")
            }
          }
        })
      )
    )
    runningServers.push(server)

    const check = await jsonRequest(server, "/v1/update?refresh=1")
    expect(check.status).toBe(500)
    expect(check.body).toEqual({ error: "release feed unreachable" })
  })
})

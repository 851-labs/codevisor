import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, Harness } from "@codevisor/api"
import { Effect, Schema } from "effect"
import { describe, expect, it } from "vitest"

import { observableFixture } from "../changes-test-support.js"
import {
  jsonRequest,
  makeServices,
  run,
  startWithApp,
  waitFor,
  listSubjectEvents
} from "../test-support.js"
import { field, idOf, itemsOf } from "./response-test-support.js"

describe("harness update checks", () => {
  it("forces a check and returns the decorated harness list", async () => {
    const { services } = await makeServices("server-a")
    const checks: Array<readonly [boolean, ReadonlyArray<string> | undefined]> = []
    const lifecycle = {
      beginBundledAppUpdate: async () => {},
      beginInstall: async () => ({ terminalId: "unused" }),
      prepareUpdate: async () => ({ phase: "updating" as const }),
      applyUpdate: async () => true,
      cancelUpdate: () => {},
      bundledAppInfo: async () => undefined,
      checkForUpdates: async (force?: boolean, harnessIds?: ReadonlyArray<string>) => {
        checks.push([force === true, harnessIds])
        return []
      },
      decorateHarnesses: async (list: ReadonlyArray<Harness>) =>
        list.map((harness) => ({
          ...harness,
          updateInfo: { latestVersion: "9.9.9", updateAvailable: true }
        })),
      beginUninstall: async () => {},
      isGated: () => false,
      notifyTurnEnded: () => {},
      notifyTurnStarted: () => {},
      onGateReleased: () => () => {},
      finishPendingSetup: async () => {},
      startPeriodicChecks: () => () => {},
      subscribe: () => () => {}
    }
    const server = await startWithApp({ ...services, lifecycle })

    const response = await jsonRequest(server, "/v1/harnesses/check-updates", { method: "POST" })
    expect(response.status).toBe(200)
    expect(checks).toEqual([[true, undefined]])
    await jsonRequest(server, "/v1/harnesses/check-updates", {
      body: JSON.stringify({ harnessIds: ["codex", 7] }),
      method: "POST"
    })
    expect(checks.at(-1)).toEqual([true, ["codex"]])
    expect(response.body).toMatchObject([
      { id: "codex", updateInfo: { latestVersion: "9.9.9", updateAvailable: true } }
    ])

    const plain = await jsonRequest(server, "/v1/harnesses")
    expect(field(itemsOf(plain.body)[0], "updateInfo")).toBeUndefined()
    const decorated = await jsonRequest(server, "/v1/harnesses?include=lifecycle")
    expect(decorated.body).toMatchObject([{ id: "codex", updateInfo: { updateAvailable: true } }])
  })

  it("drives install, update, pending, and bundled-app routes", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<string> = []
    const lifecycle = {
      beginBundledAppUpdate: async (id: string) => {
        if (id !== "codex") throw new Error("no bundled desktop app")
        calls.push(`bundled-update ${id}`)
      },
      beginInstall: async (id: string, methodId?: string) => {
        if (methodId === "carrier-pigeon") throw "no runnable install method"
        calls.push(`install ${id} ${methodId ?? "auto"}`)
        return { terminalId: "terminal-9" }
      },
      prepareUpdate: async (id: string) => {
        if (id === "kimi") throw new Error("kimi has no update source")
        calls.push(`prepare ${id}`)
        return { phase: "updating" as const }
      },
      applyUpdate: async (id: string) => {
        calls.push(`update ${id}`)
        return true
      },
      cancelUpdate: () => {},
      bundledAppInfo: async (id: string) =>
        id === "codex"
          ? {
              appName: "ChatGPT",
              bundlePath: "/Applications/ChatGPT.app",
              installedVersion: "1.0",
              latestVersion: "2.0",
              updateAvailable: true
            }
          : undefined,
      checkForUpdates: async () => [],
      decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
      beginUninstall: async () => {},
      isGated: () => false,
      notifyTurnEnded: () => {},
      notifyTurnStarted: () => {},
      onGateReleased: () => () => {},
      finishPendingSetup: async () => {},
      startPeriodicChecks: () => () => {},
      subscribe: () => () => {}
    }
    const server = await startWithApp({ ...services, lifecycle })

    const install = await jsonRequest(server, "/v1/harnesses/codex/install", {
      body: JSON.stringify({ methodId: "brew" }),
      method: "POST"
    })
    expect(install.status).toBe(202)
    expect(install.body).toMatchObject({ accepted: true, terminalId: "terminal-9" })
    const autoInstall = await jsonRequest(server, "/v1/harnesses/codex/install", {
      body: JSON.stringify({}),
      method: "POST"
    })
    expect(autoInstall.status).toBe(202)
    const badInstall = await jsonRequest(server, "/v1/harnesses/codex/install", {
      body: JSON.stringify({ methodId: "carrier-pigeon" }),
      method: "POST"
    })
    expect(badInstall.status).toBe(409)
    expect(badInstall.body).toMatchObject({ error: "no runnable install method" })
    expect(await run(services.db.getSyncEntries("harnesses"))).toMatchObject([
      { key: "codex", value: { name: "Codex", enabled: true, installed: true, uninstall: false } }
    ])

    const update = await jsonRequest(server, "/v1/harnesses/codex/update", { method: "POST" })
    expect(update.status).toBe(202)
    expect(update.body).toMatchObject({
      accepted: true,
      lifecycle: { phase: "updating" },
      queued: false
    })
    await waitFor(
      async () => field((await jsonRequest(server, "/v1/updates/run")).body, "state") === "idle"
    )
    const badUpdate = await jsonRequest(server, "/v1/harnesses/kimi/update", { method: "POST" })
    expect(badUpdate.status).toBe(409)

    const bundled = await jsonRequest(server, "/v1/harnesses/codex/bundled-app")
    expect(bundled.status).toBe(200)
    expect(bundled.body).toMatchObject({ appName: "ChatGPT", updateAvailable: true })
    const noBundle = await jsonRequest(server, "/v1/harnesses/gemini/bundled-app")
    expect(noBundle.status).toBe(404)
    const bundledUpdate = await jsonRequest(server, "/v1/harnesses/codex/bundled-app/update", {
      method: "POST"
    })
    expect(bundledUpdate.status).toBe(202)
    const badBundled = await jsonRequest(server, "/v1/harnesses/gemini/bundled-app/update", {
      method: "POST"
    })
    expect(badBundled.status).toBe(409)

    expect(calls).toEqual([
      "install codex brew",
      "install codex auto",
      "prepare codex",
      "update codex",
      "bundled-update codex"
    ])
  })

  it("enable and disable author the fleet catalog, so Settings and the picker agree", async () => {
    const { services } = await makeServices("catalog-writes")
    await run(
      services.db.mergeSyncEntries("harnesses", [
        {
          key: "codex",
          value: { name: "Codex", enabled: true, installed: true },
          timestamp: { wallMs: 1, counter: 0, deviceId: "test" }
        }
      ])
    )
    const server = await startWithApp(services)
    const disabled = await jsonRequest(server, "/v1/harnesses/codex", {
      method: "PATCH",
      body: JSON.stringify({ enabled: false })
    })
    expect(disabled.status).toBe(200)
    expect(disabled.body).toMatchObject({
      enabled: false,
      desiredEnabled: false,
      settings: { global: { enabled: false, installed: true } }
    })
    expect(decode(Harness)(disabled.body).settings?.override).toBeUndefined()
    expect(await run(services.db.getSyncEntries("harnesses"))).toMatchObject([
      { key: "codex", value: { name: "Codex", enabled: false, installed: true, uninstall: false } }
    ])

    const enabled = await jsonRequest(server, "/v1/harnesses/codex", {
      method: "PATCH",
      body: JSON.stringify({ enabled: true })
    })
    expect(enabled.body).toMatchObject({
      desiredEnabled: true,
      settings: { global: { enabled: true, installed: true } }
    })
    await run(
      services.db.mergeSyncEntries("local.harness-overrides", [
        {
          key: "codex",
          value: { enabled: false, installed: false },
          timestamp: { wallMs: 2, counter: 0, deviceId: "test" }
        }
      ])
    )
    expect(
      decode(Schema.Array(Harness))((await jsonRequest(server, "/v1/harnesses")).body).find(
        (harness) => harness.id === "codex"
      )
    ).toMatchObject({ desiredEnabled: true })
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/unknown", {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(404)
  })

  it("returns not found if a harness disappears during a machine edit", async () => {
    const { services } = await makeServices("disappeared")
    const server = await startWithApp({
      ...services,
      agents: { ...services.agents, discoverHarnesses: Effect.succeed([]) }
    })
    const response = await jsonRequest(server, "/v1/harnesses/codex", {
      method: "PATCH",
      body: JSON.stringify({ enabled: false })
    })
    expect(response.status).toBe(404)
  })

  it("returns 501 without a lifecycle manager", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)

    for (const [path, method] of [
      ["/v1/harnesses/check-updates", "POST"],
      ["/v1/harnesses/codex/install", "POST"],
      ["/v1/harnesses/codex/update", "POST"],
      ["/v1/harnesses/codex/bundled-app", "GET"],
      ["/v1/harnesses/codex/bundled-app/update", "POST"]
    ] as const) {
      const response = await jsonRequest(server, path, { method })
      expect(response.status, `${method} ${path}`).toBe(501)
    }
  })

  it("holds prompts while the harness update gate is closed and dispatches on release", async () => {
    const { agents, services } = await makeServices("server-a")
    const gated = new Set<string>()
    const turns: Array<string> = observableFixture([])
    let releaseListener: ((harnessId: string) => void) | undefined
    const lifecycle = {
      beginBundledAppUpdate: async () => {},
      beginInstall: async () => ({ terminalId: "unused" }),
      prepareUpdate: async () => ({ phase: "updating" as const }),
      applyUpdate: async () => true,
      cancelUpdate: () => {},
      bundledAppInfo: async () => undefined,
      checkForUpdates: async () => [],
      decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
      beginUninstall: async () => {},
      isGated: (harnessId: string) => gated.has(harnessId),
      notifyTurnEnded: (harnessId: string) => turns.push(`end ${harnessId}`),
      notifyTurnStarted: (harnessId: string) => turns.push(`start ${harnessId}`),
      onGateReleased: (listener: (harnessId: string) => void) => {
        releaseListener = listener
        return () => {}
      },
      finishPendingSetup: async () => {},
      startPeriodicChecks: () => () => {},
      subscribe: () => () => {}
    }
    const server = await startWithApp({ ...services, lifecycle })

    const folder = join(mkdtempSync(join(tmpdir(), "codevisor-gate-")), "repo")
    mkdirSync(folder, { recursive: true })
    const projectId = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath: folder }),
          method: "POST"
        })
      ).body
    )
    const sessionId = idOf(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ harnessId: "codex", projectId, title: "Gated" }),
          method: "POST"
        })
      ).body
    )

    gated.add("codex")
    const accepted = await jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
      body: JSON.stringify({ text: "held prompt" }),
      method: "POST"
    })
    expect(accepted.status).toBe(202)
    const second = await jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
      body: JSON.stringify({ text: "also held" }),
      method: "POST"
    })
    expect(second.status).toBe(202)
    await waitFor(async () =>
      listSubjectEvents(services, sessionId).some(
        (event) => event.kind === "session.updateGate.updated"
      )
    )
    expect(agents.prompts).toHaveLength(0)
    const heldEvents = listSubjectEvents(services, sessionId)
    expect(
      heldEvents.some(
        (event) =>
          event.kind === "session.updateGate.updated" && field(event.payload, "state") === "waiting"
      )
    ).toBe(true)
    expect((await jsonRequest(server, `/v1/sessions/${sessionId}/transcript`)).body).toMatchObject({
      updateGate: { harnessId: "codex" }
    })
    expect((await jsonRequest(server, `/v1/sessions/${sessionId}`)).body).toMatchObject({
      updateGate: { harnessId: "codex" }
    })

    releaseListener?.("gemini")

    gated.delete("codex")
    releaseListener?.("codex")
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[0]?.[1]).toBe("held prompt")
    await waitFor(() => turns.includes("end codex"))
    expect(turns[0]).toBe("start codex")
    expect(
      listSubjectEvents(services, sessionId)
        .filter(
          (event) =>
            event.kind === "session.updateGate.updated" &&
            field(event.payload, "state") === "released"
        )
        .map((event) => field(event.payload, "harnessId"))
    ).toEqual(["codex"])
    expect(
      (await jsonRequest(server, `/v1/sessions/${sessionId}/transcript`)).body
    ).not.toHaveProperty("updateGate")
  })
})

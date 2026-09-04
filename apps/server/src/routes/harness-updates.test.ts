import type { Harness } from "@codevisor/api"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  waitFor
} from "../test-support.js"

describe("harness update checks", () => {
  it("forces a check and returns the decorated harness list", async () => {
    const { services } = await makeServices("server-a")
    const checks: Array<boolean> = []
    const lifecycle = {
      beginBundledAppUpdate: async () => {},
      beginInstall: async () => ({ terminalId: "unused" }),
      beginUpdate: async () => ({ queued: false }),
      bundledAppInfo: async () => undefined,
      cancelPendingUpdate: async () => {},
      checkForUpdates: async (force?: boolean) => {
        checks.push(force === true)
        return []
      },
      decorateHarnesses: async (list: ReadonlyArray<Harness>) =>
        list.map((harness) => ({
          ...harness,
          updateInfo: { latestVersion: "9.9.9", updateAvailable: true }
        })),
      forcePendingUpdate: async () => {},
      installMethods: async () => [],
      isGated: () => false,
      notifyTurnEnded: () => {},
      notifyTurnStarted: () => {},
      onGateReleased: () => () => {},
      reconcileOnStartup: async () => {},
      startPeriodicChecks: () => () => {},
      subscribe: () => () => {}
    }
    const server = await startWithApp({ ...services, lifecycle })
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/harnesses/check-updates", { method: "POST" })
    expect(response.status).toBe(200)
    expect(checks).toEqual([true])
    expect(response.body).toMatchObject([
      { id: "codex", updateInfo: { latestVersion: "9.9.9", updateAvailable: true } }
    ])

    // Lifecycle decoration is opt-in: the plain list (the composer picker's
    // path) skips it, ?include=lifecycle carries it.
    const plain = await jsonRequest(server, "/v1/harnesses")
    expect((plain.body as Array<{ updateInfo?: unknown }>)[0]?.updateInfo).toBeUndefined()
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
        // Non-Error throw exercises the conflict mapping's String branch.
        // oxlint-disable-next-line no-throw-literal
        if (methodId === "carrier-pigeon") throw "no runnable install method"
        calls.push(`install ${id} ${methodId ?? "auto"}`)
        return { terminalId: "terminal-9" }
      },
      beginUpdate: async (id: string) => {
        if (id === "kimi") throw new Error("kimi has no update source")
        calls.push(`update ${id}`)
        return { lifecycle: { phase: "pendingUpdate" as const }, queued: true }
      },
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
      cancelPendingUpdate: async (id: string) => {
        if (id !== "codex") throw new Error("No pending update")
        calls.push(`cancel ${id}`)
      },
      checkForUpdates: async () => [],
      decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
      forcePendingUpdate: async (id: string) => {
        if (id !== "codex") throw new Error("No pending update")
        calls.push(`force ${id}`)
      },
      installMethods: async () => [],
      isGated: () => false,
      notifyTurnEnded: () => {},
      notifyTurnStarted: () => {},
      onGateReleased: () => () => {},
      reconcileOnStartup: async () => {},
      startPeriodicChecks: () => () => {},
      subscribe: () => () => {}
    }
    const server = await startWithApp({ ...services, lifecycle })
    runningServers.push(server)

    const install = await jsonRequest(server, "/v1/harnesses/codex/install", {
      body: JSON.stringify({ methodId: "brew" }),
      method: "POST"
    })
    expect(install.status).toBe(202)
    expect(install.body).toMatchObject({ accepted: true, terminalId: "terminal-9" })
    // Method omitted → the server resolves the recommended one.
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

    // Custom-harness collection accepts only GET/PUT — other verbs fall
    // through to later routes rather than mutating the store.
    const wrongMethod = await jsonRequest(server, "/v1/harnesses/custom", {
      body: JSON.stringify({}),
      method: "POST"
    })
    expect(wrongMethod.status).toBeGreaterThanOrEqual(400)

    const update = await jsonRequest(server, "/v1/harnesses/codex/update", { method: "POST" })
    expect(update.status).toBe(202)
    expect(update.body).toMatchObject({
      accepted: true,
      lifecycle: { phase: "pendingUpdate" },
      queued: true
    })
    const badUpdate = await jsonRequest(server, "/v1/harnesses/kimi/update", { method: "POST" })
    expect(badUpdate.status).toBe(409)

    const pendingApply = await jsonRequest(server, "/v1/harnesses/codex/update/pending/apply", {
      method: "POST"
    })
    expect(pendingApply.status).toBe(202)
    const badApply = await jsonRequest(server, "/v1/harnesses/gemini/update/pending/apply", {
      method: "POST"
    })
    expect(badApply.status).toBe(409)
    const pendingCancel = await jsonRequest(server, "/v1/harnesses/codex/update/pending", {
      method: "DELETE"
    })
    expect(pendingCancel.status).toBe(204)
    const badCancel = await jsonRequest(server, "/v1/harnesses/gemini/update/pending", {
      method: "DELETE"
    })
    expect(badCancel.status).toBe(409)

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
      "update codex",
      "force codex",
      "cancel codex",
      "bundled-update codex"
    ])
  })

  it("returns 501 without a lifecycle manager", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)

    for (const [path, method] of [
      ["/v1/harnesses/check-updates", "POST"],
      ["/v1/harnesses/codex/install", "POST"],
      ["/v1/harnesses/codex/update", "POST"],
      ["/v1/harnesses/codex/update/pending/apply", "POST"],
      ["/v1/harnesses/codex/update/pending", "DELETE"],
      ["/v1/harnesses/codex/bundled-app", "GET"],
      ["/v1/harnesses/codex/bundled-app/update", "POST"],
      ["/v1/harnesses/custom/test", "POST"]
    ] as const) {
      const response = await jsonRequest(server, path, { method })
      expect(response.status, `${method} ${path}`).toBe(501)
    }
  })

  it("holds prompts while the harness update gate is closed and dispatches on release", async () => {
    const { agents, services } = await makeServices("server-a")
    const gated = new Set<string>()
    const turns: Array<string> = []
    let releaseListener: ((harnessId: string) => void) | undefined
    const lifecycle = {
      beginBundledAppUpdate: async () => {},
      beginInstall: async () => ({ terminalId: "unused" }),
      beginUpdate: async () => ({ queued: false }),
      bundledAppInfo: async () => undefined,
      cancelPendingUpdate: async () => {},
      checkForUpdates: async () => [],
      decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
      forcePendingUpdate: async () => {},
      installMethods: async () => [],
      isGated: (harnessId: string) => gated.has(harnessId),
      notifyTurnEnded: (harnessId: string) => turns.push(`end ${harnessId}`),
      notifyTurnStarted: (harnessId: string) => turns.push(`start ${harnessId}`),
      onGateReleased: (listener: (harnessId: string) => void) => {
        releaseListener = listener
        return () => {}
      },
      reconcileOnStartup: async () => {},
      startPeriodicChecks: () => () => {},
      subscribe: () => () => {}
    }
    const server = await startWithApp({ ...services, lifecycle })
    runningServers.push(server)

    const folder = join(mkdtempSync(join(tmpdir(), "codevisor-gate-")), "repo")
    mkdirSync(folder, { recursive: true })
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ harnessId: "codex", projectId: project.id, title: "Gated" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    // Gate closed: the prompt is accepted (202, durable) but never reaches
    // the provider.
    gated.add("codex")
    const accepted = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "held prompt" }),
      method: "POST"
    })
    expect(accepted.status).toBe(202)
    // A second send while held re-queues without a duplicate hold marker.
    const second = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "also held" }),
      method: "POST"
    })
    expect(second.status).toBe(202)
    await new Promise((resolve) => setTimeout(resolve, 150))
    expect(agents.prompts).toHaveLength(0)
    // The transcript-facing hold marker was persisted for replay.
    const heldEvents = await run(services.db.listSubjectEvents(session.id))
    expect(
      heldEvents.some(
        (event) =>
          event.kind === "session.updateGate.updated" &&
          (event.payload as { state?: string }).state === "waiting"
      )
    ).toBe(true)
    // Snapshots carry the live gate, so a client (re)opening the chat shows
    // the marker without having to have seen the event.
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/transcript`)).body).toMatchObject(
      { updateGate: { harnessId: "codex" } }
    )
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      updateGate: { harnessId: "codex" }
    })

    // A release for a different harness leaves this session held.
    releaseListener?.("gemini")
    await new Promise((resolve) => setTimeout(resolve, 100))
    expect(agents.prompts).toHaveLength(0)

    // Gate releases → the held prompts dispatch and turn accounting ran.
    gated.delete("codex")
    releaseListener?.("codex")
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[0]?.[1]).toBe("held prompt")
    await waitFor(() => turns.includes("end codex"))
    expect(turns[0]).toBe("start codex")
    // Released: snapshots no longer carry a gate.
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/transcript`)).body
    ).not.toHaveProperty("updateGate")
  })
})

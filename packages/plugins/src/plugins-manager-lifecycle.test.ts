import { rmSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"
import type { PluginStateEvent } from "./plugins-manager.js"
import { cleanups, exampleManifest, makeManager, makeOuterServer } from "./test-support.js"

/// Manager-level supervision behaviors: explicit restart, state-change
/// fanout, and WS pinning against the idle lifecycle.

describe("restart", () => {
  it("stops the running process, clears crash state, and returns the summary", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect((await manager.get("owner.example")).state).toBe("running")
    const summary = await manager.restart("owner.example")
    expect(summary.id).toBe("owner.example")
    expect(summary.state).toBe("stopped")
    // The next pane request relaunches fresh.
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect((await manager.get("owner.example")).state).toBe("running")
  })

  it("rejects restarting plugins that are not installed", async () => {
    const { manager } = makeManager()
    await expect(manager.restart("owner.ghost")).rejects.toThrow(/not installed/)
  })
})

describe("state events", () => {
  it("emits a summary on every transition and stops after unsubscribe", async () => {
    const { manager } = makeManager()
    const events: Array<PluginStateEvent> = []
    const unsubscribe = manager.subscribe((event) => events.push(event))
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect(events.map((event) => event.payload.state)).toEqual(["starting", "running"])
    expect(events[0]?.kind).toBe("plugin.state.updated")
    expect(events[0]?.subjectId).toBe("owner.example")
    expect(events[0]?.payload.id).toBe("owner.example")
    await manager.restart("owner.example")
    expect(events.map((event) => event.payload.state)).toEqual([
      "starting",
      "running",
      "stopping",
      "stopped"
    ])
    unsubscribe()
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    expect(events).toHaveLength(4)
  })

  it("skips events for plugins removed from disk mid-flight", async () => {
    const { manager, root } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    const events: Array<PluginStateEvent> = []
    manager.subscribe((event) => events.push(event))
    rmSync(join(root, "example"), { force: true, recursive: true })
    // Shutdown still transitions the runtime, but there is no plugin left to
    // summarize — the event is dropped instead of throwing.
    manager.close()
    expect(events).toHaveLength(0)
  })
})

describe("idle lifecycle", () => {
  it(
    "open websockets pin the process; closing them lets it idle out",
    { timeout: 15_000 },
    async () => {
      // The manifest schema only allows whole seconds, so this integration
      // test runs on a real 1s idle window (fast idle mechanics are unit
      // tested against the supervisor directly).
      const { manager } = makeManager({}, { ...exampleManifest, idleTimeoutSeconds: 1 })
      const outer = await makeOuterServer(manager)
      const socket = await new Promise<WebSocket>((resolve, reject) => {
        const candidate = new WebSocket(
          `ws://127.0.0.1:${outer.port}/v1/plugins/owner.example/app/live`
        )
        cleanups.push(() => candidate.close())
        candidate.on("open", () => resolve(candidate))
        candidate.on("error", reject)
      })
      await new Promise<string>((resolve) => {
        socket.on("message", (data) => resolve(String(data)))
        socket.send("ping")
      })
      // Well past the idle window, the open splice keeps the process alive.
      await new Promise((resolve) => setTimeout(resolve, 1_400))
      expect((await manager.get("owner.example")).state).toBe("running")
      socket.close()
      await expect
        .poll(async () => (await manager.get("owner.example")).state, { timeout: 6_000 })
        .toBe("stopped")
    }
  )
})

import { describe, expect, it } from "vitest"
import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { makeBrowserToolInvoker, type BrowserToolSessionState } from "./browser-use-invoke.js"

const context = { sessionId: "tab-group-session", projectId: "project" }

const harness = (backend: "extension" | "managed" = "extension") => {
  const sent: Array<{ method: string; params: unknown }> = []
  const state: BrowserToolSessionState = {
    assetInventories: new Map(),
    assetsDir: "/tmp/assets",
    downloadsDir: "/tmp/downloads",
    selectedTargets: new Map(),
    sessionBackends: new Map([[context.sessionId, backend]]),
    sessionDispositions: new Map(),
    sessionTargets: new Map()
  }
  const runtime = {
    tabOrder: [],
    sessions: new Map(),
    staleSessions: new Map(),
    snapshots: new Map(),
    logs: new Map(),
    dialogs: new Map(),
    fileChoosers: new Map(),
    connection: {
      send: async (method: string, params: unknown) => {
        sent.push({ method, params })
        if (method === "Target.getTargets") {
          return {
            targetInfos: [
              { targetId: "11", type: "page", title: "Docs", url: "https://a.test/", groupId: 7 },
              { targetId: "12", type: "page", title: "Issue", url: "https://b.test/" }
            ]
          }
        }
        if (method === "Codevisor.tabGroups.list") return { groups: [{ id: 7, tabIds: ["11"] }] }
        if (method.startsWith("Codevisor.tabGroups.")) {
          return { group: { id: 7, title: "Research", color: "blue", collapsed: false } }
        }
        return {}
      }
    }
  } as unknown as BrowserRuntime
  const invoke = makeBrowserToolInvoker(state)
  const call = async (args: Readonly<Record<string, unknown>>) => {
    const result = await invoke(context, runtime, "tab_groups", args)
    const block = result.content[0]
    if (block?.type !== "text") throw new Error("Missing tool text")
    return JSON.parse(block.text) as unknown
  }
  return { call, invoke, runtime, sent }
}

describe("tab_groups", () => {
  it("relays every action to the extension with validated arguments", async () => {
    const { call, sent } = harness()
    expect(await call({ action: "list" })).toEqual({ groups: [{ id: 7, tabIds: ["11"] }] })
    expect(
      await call({ action: "create", tabIds: ["11", "12"], title: "Research", color: "blue" })
    ).toMatchObject({ group: { id: 7, title: "Research" } })
    await call({ action: "add", groupId: 7, tabIds: ["12"] })
    await call({ action: "update", groupId: 7, collapsed: true })
    expect(await call({ action: "ungroup", tabIds: ["12"] })).toEqual({ ungrouped: ["12"] })
    expect(sent).toEqual([
      { method: "Codevisor.tabGroups.list", params: {} },
      {
        method: "Codevisor.tabGroups.create",
        params: { tabIds: ["11", "12"], title: "Research", color: "blue" }
      },
      { method: "Codevisor.tabGroups.add", params: { groupId: 7, tabIds: ["12"] } },
      { method: "Codevisor.tabGroups.update", params: { groupId: 7, collapsed: true } },
      { method: "Codevisor.tabGroups.ungroup", params: { tabIds: ["12"] } }
    ])
  })

  it("ensure reuses a same-titled group and only creates when none exists", async () => {
    const { call, sent } = harness()
    // "Research" exists with tab 11: add the missing tab and restyle, do not create.
    const listed = { groups: [{ id: 7, title: "Research", tabIds: ["11"] }] }
    const first = harness()
    first.runtime.connection.send = (async (method: string, params: unknown) => {
      first.sent.push({ method, params })
      if (method === "Codevisor.tabGroups.list") return listed
      return { group: { id: 7, title: "Research", color: "green" } }
    }) as never
    expect(
      await first.call({
        action: "ensure",
        tabIds: ["11", "12"],
        title: "Research",
        color: "green"
      })
    ).toMatchObject({ group: { id: 7 }, created: false })
    expect(first.sent.map((entry) => [entry.method, entry.params])).toEqual([
      ["Codevisor.tabGroups.list", {}],
      ["Codevisor.tabGroups.add", { groupId: 7, tabIds: ["12"] }],
      ["Codevisor.tabGroups.update", { groupId: 7, color: "green" }]
    ])

    // No such title: create it.
    expect(await call({ action: "ensure", tabIds: ["12"], title: "Scratch" })).toMatchObject({
      group: { id: 7 },
      created: true
    })
    expect(sent.map((entry) => [entry.method, entry.params])).toEqual([
      ["Codevisor.tabGroups.list", {}],
      ["Codevisor.tabGroups.create", { tabIds: ["12"], title: "Scratch" }]
    ])
    await expect(call({ action: "ensure", tabIds: ["12"] })).rejects.toThrow(
      "title must be a string"
    )
  })

  it("keeps handed-off tabs visible to later turns without ever closing them", async () => {
    const { invoke, runtime } = harness()
    const text = (result: Awaited<ReturnType<typeof invoke>>) => {
      const block = result.content[0]
      if (block?.type !== "text") throw new Error("Missing tool text")
      return JSON.parse(block.text) as Record<string, unknown>
    }
    runtime.connection.send = (async (method: string) => {
      if (method === "Target.getTargets") {
        return {
          targetInfos: [
            { targetId: "11", type: "page", title: "Docs", url: "https://a.test/" },
            { targetId: "12", type: "page", title: "Issue", url: "https://b.test/" }
          ]
        }
      }
      if (method === "Target.createTarget") return { targetId: "11" }
      return {}
    }) as never
    await invoke(context, runtime, "tabs", { action: "new", url: "https://a.test/" })
    expect(
      text(await invoke(context, runtime, "finalizeTabs", { native: true, keepIds: ["11"] }))
    ).toEqual({ finalized: true, kept: ["11"], closed: [], released: [] })
    expect(
      text(await invoke(context, runtime, "tabs", { action: "list", scope: "session" }))
    ).toMatchObject({ tabs: [{ id: "11", origin: "kept" }] })
    // A per-tab call after finalize re-selects the tab; it stays "kept", not re-claimed.
    await invoke(context, runtime, "tabs", { action: "select", id: "11" })
    // A later finalize that keeps nothing must not close a tab already handed to the user.
    expect(
      text(await invoke(context, runtime, "finalizeTabs", { native: true, keepIds: [] }))
    ).toEqual({ finalized: true, kept: ["11"], closed: [], released: [] })
  })

  it("rejects malformed arguments before touching the browser", async () => {
    const { call, sent } = harness()
    for (const [args, message] of [
      [{ action: "create" }, "tabIds must be a non-empty array of tab ids"],
      [{ action: "create", tabIds: [] }, "tabIds must be a non-empty array of tab ids"],
      [{ action: "create", tabIds: [12] }, "tabIds must be a non-empty array of tab ids"],
      [{ action: "create", tabIds: ["12"], color: "beige" }, "color must be one of grey"],
      [{ action: "create", tabIds: ["12"], title: 5 }, "title must be a string"],
      [{ action: "update", groupId: 7, collapsed: "yes" }, "collapsed must be a boolean"],
      [{ action: "update", groupId: "7" }, "groupId must be the id of a group"],
      [{ action: "add", groupId: -1, tabIds: ["12"] }, "groupId must be the id of a group"],
      [
        { action: "rename" },
        "tab_groups.action must be list, create, ensure, add, update, or ungroup"
      ]
    ] as const) {
      await expect(call(args), JSON.stringify(args)).rejects.toThrow(message)
    }
    expect(sent).toEqual([])
  })

  it("is unavailable on the managed browser", async () => {
    const { call, sent } = harness("managed")
    await expect(call({ action: "list" })).rejects.toThrow(
      "Tab groups are only available with the user Chrome backend"
    )
    expect(sent).toEqual([])
  })

  it("reports group membership in tab listings", async () => {
    const { invoke, runtime } = harness()
    const result = await invoke(context, runtime, "tabs", { action: "list" })
    const block = result.content[0]
    if (block?.type !== "text") throw new Error("Missing tool text")
    expect(JSON.parse(block.text)).toMatchObject({
      tabs: [{ id: "11", groupId: 7 }, { id: "12" }]
    })
    expect((JSON.parse(block.text) as { tabs: Array<object> }).tabs[1]).not.toHaveProperty(
      "groupId"
    )
  })
})

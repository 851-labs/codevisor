import { describe, expect, it } from "vitest"

import type { BrowserRuntime } from "./browser-cdp-engine.js"
import type { CdpConnection } from "./browser-cdp.js"
import { browserResultValue } from "./browser-repl.js"
import { makeBrowserToolInvoker, type BrowserToolSessionState } from "./browser-use-invoke.js"

/// Tab ownership and turn-end cleanup are our bookkeeping over Chrome's
/// target list, so a stateful fake of that list proves them without a real
/// browser. Page behavior (DOM, accessibility, trusted input, frames) stays
/// in the *.chrome.test.ts suite.
const harness = () => {
  const context = { projectId: "project", sessionId: "session" }
  const targets: Array<{ targetId: string; type: string; title: string; url: string }> = []
  const sent: Array<{ method: string; params: Readonly<Record<string, unknown>> }> = []
  let created = 0
  const send = async (
    method: string,
    params: Readonly<Record<string, unknown>> = {},
    sessionId?: string
  ) => {
    sent.push({ method, params })
    switch (method) {
      case "Target.createTarget": {
        const targetId = `tab-${++created}`
        targets.push({ targetId, type: "page", title: targetId, url: String(params.url) })
        return { targetId }
      }
      case "Target.closeTarget": {
        const index = targets.findIndex((target) => target.targetId === params.targetId)
        if (index >= 0) targets.splice(index, 1)
        return { success: true }
      }
      case "Target.getTargets":
        return { targetInfos: [...targets] }
      case "Target.attachToTarget":
        return { sessionId: `cdp:${String(params.targetId)}` }
      case "Runtime.evaluate": {
        const target = targets.find((candidate) => `cdp:${candidate.targetId}` === sessionId)
        return { result: { value: { title: target?.title ?? "", url: target?.url ?? "" } } }
      }
      default:
        return {}
    }
  }
  const state: BrowserToolSessionState = {
    assetInventories: new Map(),
    assetsDir: "",
    downloadsDir: "",
    selectedTargets: new Map(),
    sessionBackends: new Map([[context.sessionId, "managed"]]),
    sessionDispositions: new Map(),
    sessionTargets: new Map()
  }
  const runtime: BrowserRuntime = {
    connection: { send, sendOnce: send } as unknown as CdpConnection,
    owned: false,
    processHandle: undefined,
    sessions: new Map(),
    staleSessions: new Map(),
    snapshots: new Map(),
    eventLog: [],
    logs: new Map(),
    dialogs: new Map(),
    fileChoosers: new Map(),
    downloads: new Map(),
    eventDisposers: [],
    eventSequence: 0,
    tabOrder: [],
    queue: Promise.resolve()
  }
  const invoke = makeBrowserToolInvoker(state)
  const call = async (name: string, args: Readonly<Record<string, unknown>>) =>
    browserResultValue(await invoke(context, runtime, name, args))
  const newTab = async () => {
    const { tabs } = (await call("tabs", { action: "new" })) as {
      tabs: Array<{ id: string; selected: boolean }>
    }
    return tabs.find((tab) => tab.selected)!.id
  }
  const closed = () =>
    sent
      .filter(({ method }) => method === "Target.closeTarget")
      .map(({ params }) => params.targetId)
  return { call, newTab, closed, targets }
}

describe("Browser tab lifecycle", () => {
  it("closes only unkept agent-created tabs when a turn is finalized", async () => {
    const { call, newTab, closed, targets } = harness()
    const kept = await newTab()
    const deliverable = await newTab()
    await call("markTab", { id: deliverable, status: "deliverable" })
    const scratch = await newTab()

    expect(await call("finalizeTabs", { native: true, keepIds: [kept] })).toEqual({
      finalized: true,
      kept: [kept, deliverable],
      closed: [scratch],
      released: []
    })
    expect(closed()).toEqual([scratch])
    expect(targets.map((target) => target.targetId)).toEqual([kept, deliverable])
  })

  it("rejects a closed tab instead of routing to another open tab", async () => {
    const { call, newTab } = harness()
    const first = await newTab()
    const second = await newTab()
    await call("tabs", { action: "close", id: second })

    await expect(call("tab_info", { tabId: second })).rejects.toThrow(/does not own that tab/)
    expect(await call("tab_info", { tabId: first })).toMatchObject({ id: first })
  })
})

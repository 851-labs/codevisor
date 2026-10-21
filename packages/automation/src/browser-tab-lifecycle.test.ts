import { describe, expect, it } from "vitest"

import { browserResultValue } from "./browser-repl.js"
import {
  browserToolSessionState,
  fakeBrowserRuntime,
  fakeCdpConnection
} from "./browser-runtime-test-support.js"
import { makeBrowserToolInvoker } from "./browser-use-invoke.js"
import { expectArray, expectBoolean, expectRecord, expectString } from "./unknown-values.js"

const harness = () => {
  const context = { projectId: "project", sessionId: "session" }
  const targets: Array<{ targetId: string; type: string; title: string; url: string }> = []
  const sent: Array<{
    method: string
    params: Readonly<Record<string, unknown>>
    sessionId: string | undefined
  }> = []
  const failClose = new Set<string>()
  let failCreate = false
  let created = 0
  const send = async (
    method: string,
    params: Readonly<Record<string, unknown>> = {},
    sessionId?: string
  ) => {
    sent.push({ method, params, sessionId })
    switch (method) {
      case "Target.createTarget": {
        const targetId = `tab-${++created}`
        targets.push({ targetId, type: "page", title: targetId, url: String(params.url) })
        if (failCreate) throw new Error("Timed out waiting for Target.createTarget")
        return { targetId }
      }
      case "Target.closeTarget": {
        if (failClose.has(String(params.targetId))) throw new Error("No target with given id")
        const index = targets.findIndex((target) => target.targetId === params.targetId)
        if (index >= 0) targets.splice(index, 1)
        return { success: true }
      }
      case "Target.getTargets":
        return { targetInfos: [...targets] }
      case "Target.attachToTarget":
        return { sessionId: `cdp:${String(params.targetId)}` }
      case "Runtime.evaluate": {
        if (params.expression === "document.readyState") return { result: { value: "complete" } }
        const target = targets.find((candidate) => `cdp:${candidate.targetId}` === sessionId)
        return { result: { value: { title: target?.title ?? "", url: target?.url ?? "" } } }
      }
      default:
        return {}
    }
  }
  const state = browserToolSessionState({
    sessionBackends: new Map([[context.sessionId, "managed"]])
  })
  const runtime = fakeBrowserRuntime({
    connection: fakeCdpConnection({ send, sendOnce: send }).connection
  })
  const invoke = makeBrowserToolInvoker(state)
  const call = async (name: string, args: Readonly<Record<string, unknown>>) =>
    browserResultValue(await invoke(context, runtime, name, args))
  const newTab = async () => {
    const tabs = expectArray(
      expectRecord(await call("tabs", { action: "new" }), "tabs").tabs,
      "tabs"
    )
    const selected = tabs
      .map((tab) => expectRecord(tab, "tab"))
      .find((tab) => expectBoolean(tab.selected, "tab selected"))
    return expectString(selected?.id, "selected tab id")
  }
  const closed = () =>
    sent
      .filter(({ method }) => method === "Target.closeTarget")
      .map(({ params }) => params.targetId)
  return {
    call,
    newTab,
    closed,
    sent,
    state,
    targets,
    failClose,
    failCreate: () => {
      failCreate = true
    }
  }
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

  it("creates a navigation tab before a concurrent claim of a user tab", async () => {
    const { call, sent, state, targets } = harness()
    targets.push({ targetId: "user", type: "page", title: "Inbox", url: "https://mail.test/" })

    await Promise.all([
      call("navigate", { url: "https://agent.test/" }),
      call("tabs", { action: "select", id: "user" })
    ])

    expect(sent.slice(0, 3).map(({ method }) => method)).toEqual([
      "Target.createTarget",
      "Target.getTargets",
      "Target.getTargets"
    ])
    expect(sent.find(({ method }) => method === "Page.navigate")?.sessionId).toBe("cdp:user")
    expect(state.selectedTargets.get("managed:project:session")).toBe("user")
    expect([...state.sessionTargets.get("managed:project:session")!]).toEqual([
      ["tab-1", "created"],
      ["user", "claimed"]
    ])
  })

  it.each([
    [
      "context",
      {
        get sessionId(): string {
          throw new Error("unreadable context")
        }
      },
      {}
    ],
    [
      "arguments",
      { sessionId: "session" },
      {
        get action(): string {
          throw new Error("unreadable arguments")
        }
      }
    ]
  ])("rejects instead of throwing when the %s can't be read", async (_, context, args) => {
    const invoke = makeBrowserToolInvoker(browserToolSessionState())
    let pending: Promise<unknown> | undefined
    expect(() => {
      pending = invoke(context, fakeBrowserRuntime(), "tabs", args)
    }).not.toThrow()
    await expect(pending).rejects.toThrow(/^unreadable/)
  })

  it("rejects a closed tab instead of routing to another open tab", async () => {
    const { call, newTab } = harness()
    const first = await newTab()
    const second = await newTab()
    await call("tabs", { action: "close", id: second })

    await expect(call("tab_info", { tabId: second })).rejects.toThrow(/does not own that tab/)
    expect(await call("tab_info", { tabId: first })).toMatchObject({ id: first })
  })

  it("keeps closing the rest when one tab won't close, and forgets it", async () => {
    const { call, newTab, closed, targets, failClose } = harness()
    const gone = await newTab()
    const scratch = await newTab()
    failClose.add(gone)

    expect(await call("finalizeTabs", { native: true })).toEqual({
      finalized: true,
      kept: [],
      closed: [scratch],
      released: [],
      failed: [gone]
    })
    expect(targets.map((target) => target.targetId)).toEqual([gone])
    expect(await call("finalizeTabs", { native: true })).toEqual({
      finalized: true,
      kept: [],
      closed: [],
      released: []
    })
    expect(closed()).toEqual([gone, scratch])
  })

  it("closes a tab a failed create left behind, and only that tab", async () => {
    const { call, newTab, targets, failCreate } = harness()
    const existing = await newTab()
    failCreate()

    await expect(call("tabs", { action: "new" })).rejects.toThrow(/Timed out/)
    expect(targets.map((target) => target.targetId)).toEqual([existing])
  })
})

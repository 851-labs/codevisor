import { randomUUID } from "node:crypto"
import { afterEach, beforeEach, expect, it, vi } from "vitest"
import type { BrowserRuntime } from "./browser-cdp-engine.js"
import type { CdpConnection } from "./browser-cdp.js"
import { browserResultValue } from "./browser-repl.js"
import { makeBrowserToolInvoker, type BrowserToolSessionState } from "./browser-use-invoke.js"

vi.mock("node:crypto", async (original) => ({
  ...(await original<typeof import("node:crypto")>()),
  randomUUID: vi.fn()
}))

beforeEach(() => {
  let id = 0
  vi.mocked(randomUUID).mockImplementation(
    () => `${(++id).toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`
  )
})
afterEach(() => vi.resetAllMocks())

function fixture() {
  const context = { projectId: "project", sessionId: "session" }
  const sessionKey = "managed:project:session"
  const targets = ["first", "second"].map((targetId) => ({
    targetId,
    type: "page",
    title: targetId,
    url: `https://${targetId}.test/`
  }))
  const state: BrowserToolSessionState = {
    assetInventories: new Map(),
    assetsDir: "",
    downloadsDir: "",
    selectedTargets: new Map([[sessionKey, "second"]]),
    sessionBackends: new Map([[context.sessionId, "managed"]]),
    sessionDispositions: new Map(),
    sessionTargets: new Map([
      [sessionKey, new Map(targets.map(({ targetId }) => [targetId, "created"]))]
    ])
  }
  const reads = new Map<string, ReturnType<typeof Promise.withResolvers<void>>>()
  const requested = new Map(
    targets.map(({ targetId }) => [targetId, Promise.withResolvers<void>()])
  )
  const send = vi.fn(async (method: string, _params: unknown, sessionId?: string) => {
    if (method === "Target.getTargets") return { targetInfos: targets }
    const target = targets.find(({ targetId }) => sessionId === `cdp:${targetId}`)
    if (!target) throw new Error(`Unexpected CDP session ${sessionId}`)
    if (method === "Accessibility.getFullAXTree")
      return {
        nodes: [
          { nodeId: "root", ignored: false, role: { value: "RootWebArea" }, childIds: ["button"] },
          {
            nodeId: "button",
            parentId: "root",
            ignored: false,
            role: { value: "button" },
            name: { value: "No navigation" },
            backendDOMNodeId: 42
          }
        ]
      }
    if (method === "Runtime.evaluate") {
      requested.get(target.targetId)!.resolve()
      await reads.get(target.targetId)?.promise
      return { result: { value: { title: target.title, url: target.url } } }
    }
    throw new Error(`Unexpected CDP command ${method}`)
  })
  const runtime: BrowserRuntime = {
    connection: { send } as unknown as CdpConnection,
    owned: false,
    processHandle: undefined,
    sessions: new Map(targets.map(({ targetId }) => [targetId, `cdp:${targetId}`])),
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
  const call = async (name: string, args: Record<string, unknown>, sessionId = context.sessionId) =>
    browserResultValue(await invoke({ ...context, sessionId }, runtime, name, args))
  const snapshot = async (tabId: string) => {
    const text = String(await call("snapshot", { tabId }))
    const ref = text.match(/button "No navigation" \[ref=(e\d+)\]/)?.[1]
    expect(ref).toBeTruthy()
    return ref!
  }
  return { call, snapshot, send, state, reads, requested }
}

it.each([false, true])(
  "routes overlapping reads by tab id (reverse replies: %s)",
  async (reverse) => {
    const { call, reads, requested, state } = fixture()
    for (const id of ["first", "second"]) reads.set(id, Promise.withResolvers<void>())
    const pending = Promise.all([
      call("tab_info", { tabId: "first" }),
      call("tab_info", { tabId: "second" })
    ])
    try {
      await Promise.all([...requested.values()].map(({ promise }) => promise))
      // Both reads have reached their own CDP sessions. Change the default tab
      // before either replies to prove it cannot redirect an in-flight operation.
      state.selectedTargets.set("managed:project:session", "first")
      for (const id of reverse ? ["second", "first"] : ["first", "second"]) reads.get(id)!.resolve()
      expect(await pending).toEqual([
        { id: "first", title: "first", url: "https://first.test/" },
        { id: "second", title: "second", url: "https://second.test/" }
      ])
    } finally {
      for (const gate of reads.values()) gate.resolve()
      await pending
    }
  }
)

it("rejects a ref after a newer snapshot of the same tab", async () => {
  const { call, snapshot, send } = fixture()
  const old = await snapshot("first")
  const current = await snapshot("first")
  expect(current).not.toBe(old)
  send.mockClear()
  await expect(call("click", { tabId: "first", target: old })).rejects.toThrow(/stale/)
  expect(send.mock.calls.map(([method]) => method)).toEqual(["Target.getTargets"])
})

it("rejects a ref belonging to a different tab before issuing a DOM command", async () => {
  const { call, snapshot, send } = fixture()
  const first = await snapshot("first")
  await snapshot("second")
  send.mockClear()
  await expect(call("click", { tabId: "second", target: first })).rejects.toThrow(/stale/)
  expect(send.mock.calls.map(([method]) => method)).toEqual(["Target.getTargets"])
})

it("keeps refs scoped to the owning session even when sessions share a tab", async () => {
  const { call, snapshot, state, send } = fixture()
  const first = await snapshot("first")
  state.sessionTargets.set("managed:project:other", new Map([["first", "claimed"]]))
  await call("snapshot", { tabId: "first" }, "other")
  send.mockClear()
  await expect(call("click", { tabId: "first", target: first }, "other")).rejects.toThrow(/stale/)
  expect(send.mock.calls.map(([method]) => method)).toEqual(["Target.getTargets"])
})

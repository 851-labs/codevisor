import { readFileSync } from "node:fs"
import { join } from "node:path"
import { createContext, runInContext, runInNewContext } from "node:vm"

import { expect, it, vi } from "vitest"

import { browserExtensionPath } from "./browser-extension-relay.js"

const script = (name: string): string => readFileSync(join(browserExtensionPath()!, name), "utf8")

it("creates a tab group using only tabs shared with Codevisor", async () => {
  const group = vi.fn(async () => 7)
  const update = vi.fn(async () => undefined)
  const context = createContext({
    chrome: {
      tabs: { group, query: async () => [{ id: 11 }] },
      tabGroups: { update, get: async () => ({ id: 7, color: "blue", windowId: 1 }) }
    }
  })
  runInContext(script("tab-groups.js"), context)
  const handle = context.handleTabGroupCommand as (
    allowed: Set<number>,
    message: unknown
  ) => Promise<unknown>
  const request = {
    method: "Codevisor.tabGroups.create",
    params: { tabIds: ["11"], color: "blue" }
  }
  expect(await handle(new Set([11]), request)).toEqual({
    group: { id: 7, title: "", color: "blue", collapsed: false, windowId: 1, tabIds: ["11"] }
  })
  expect(group).toHaveBeenCalledExactlyOnceWith({ tabIds: [11] })
  expect(update).toHaveBeenCalledExactlyOnceWith(7, { color: "blue" })
  await expect(handle(new Set(), request)).rejects.toThrow("not shared with Codevisor")
  expect(group).toHaveBeenCalledOnce()
})

const clipboard = () => {
  const getData = vi.fn(() => "copied text")
  const setData = vi.fn()
  const listeners = new Map<string, (event: unknown) => void>()
  let dispatch!: (message: unknown) => Promise<unknown>
  const execCommand = vi.fn((type: string) => {
    const listener = listeners.get(type)
    listeners.delete(type)
    listener?.({ preventDefault: () => undefined, clipboardData: { getData, setData } })
    return true
  })
  runInNewContext(script("offscreen.js"), {
    Blob,
    chrome: {
      runtime: { onMessage: { addListener: (listener: typeof dispatch) => (dispatch = listener) } }
    },
    document: {
      addEventListener: (type: string, listener: (event: unknown) => void) =>
        listeners.set(type, listener),
      removeEventListener: (type: string) => listeners.delete(type),
      execCommand
    }
  })
  return { dispatch, execCommand, getData, setData }
}

it("reads text through the offscreen clipboard event", async () => {
  const f = clipboard()
  expect(await f.dispatch({ target: "codevisor-offscreen", method: "readText" })).toEqual({
    ok: true,
    result: { text: "copied text" }
  })
  expect(f.execCommand).toHaveBeenCalledExactlyOnceWith("paste")
  expect(f.getData).toHaveBeenCalledExactlyOnceWith("text/plain")
})

it("writes supplied text through the offscreen clipboard event", async () => {
  const f = clipboard()
  expect(
    await f.dispatch({
      target: "codevisor-offscreen",
      method: "writeText",
      params: { text: "日本語" }
    })
  ).toEqual({
    ok: true,
    result: { written: true }
  })
  expect(f.execCommand).toHaveBeenCalledExactlyOnceWith("copy")
  expect(f.setData).toHaveBeenCalledExactlyOnceWith("text/plain", "日本語")
})

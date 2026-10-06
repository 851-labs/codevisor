import { textToolResult, type AutomationToolProvider } from "@codevisor/automation"
import { describe, expect, it } from "vitest"

import { makeAutomationUse, type AutomationTool } from "./mcp-automation-use.js"

const provider = (id: AutomationToolProvider["id"]) => {
  const calls: Array<string> = []
  const value: AutomationToolProvider = {
    id,
    tools: [],
    invoke: async (_context, toolName) => {
      calls.push(`invoke:${toolName}`)
      return textToolResult("ok")
    },
    closeSession: async (sessionId) => {
      calls.push(`close:${sessionId}`)
    },
    close: async () => undefined
  }
  return { value, calls }
}

describe("automation use", () => {
  it("reports the tool a session touched last, once per switch", async () => {
    const use = makeAutomationUse()
    const browser = provider("browser")
    const computer = provider("computer")
    const trackedBrowser = use.track(browser.value)
    const trackedComputer = use.track(computer.value)
    const seen: Array<AutomationTool> = []
    const unsubscribe = use.subscribe("chat", (tool) => seen.push(tool))

    await trackedBrowser.invoke({ sessionId: "chat" }, "tabs", {})
    await trackedBrowser.invoke({ sessionId: "chat" }, "click", {})
    await trackedComputer.invoke({ sessionId: "chat" }, "computer.js", {})
    await trackedBrowser.invoke({ sessionId: "other" }, "tabs", {})
    await trackedBrowser.invoke({ sessionId: "chat" }, "scroll", {})
    expect(seen).toEqual(["browser", "computer", "browser"])
    expect(browser.calls).toEqual(["invoke:tabs", "invoke:click", "invoke:tabs", "invoke:scroll"])
    expect(computer.calls).toEqual(["invoke:computer.js"])

    // A late subscriber hears the current tool straight away.
    const late: Array<AutomationTool> = []
    const unsubscribeLate = use.subscribe("chat", (tool) => late.push(tool))
    expect(late).toEqual(["browser"])

    unsubscribe()
    unsubscribeLate()
    await trackedComputer.invoke({ sessionId: "chat" }, "computer.js", {})
    expect(seen).toEqual(["browser", "computer", "browser"])

    // A repeated unsubscribe doesn't drop a newer subscriber.
    const newer: Array<AutomationTool> = []
    use.subscribe("chat", (tool) => newer.push(tool))
    unsubscribe()
    await trackedBrowser.invoke({ sessionId: "chat" }, "tabs", {})
    expect(newer).toEqual(["computer", "browser"])
  })

  it("forgets a closed session and leaves other providers alone", async () => {
    const use = makeAutomationUse()
    const computer = provider("computer")
    const tracked = use.track(computer.value)
    await tracked.invoke({ sessionId: "chat" }, "computer.js", {})
    await tracked.closeSession("chat")
    expect(computer.calls).toEqual(["invoke:computer.js", "close:chat"])
    const seen: Array<AutomationTool> = []
    use.subscribe("chat", (tool) => seen.push(tool))()
    expect(seen).toEqual([])

    const codevisor = provider("codevisor").value
    expect(use.track(codevisor)).toBe(codevisor)
  })
})

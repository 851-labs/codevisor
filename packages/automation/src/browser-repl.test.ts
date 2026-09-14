import { expect, it } from "vitest"
import { browserResultValue, makeBrowserRepls } from "./browser-repl.js"

// Handle lifetime and concurrent result routing belong to the REPL, independent
// of Chrome's background renderer scheduling. Hold both calls at the tool boundary.
it.each([false, true])(
  "preserves tab handles across cells (reverse replies: %s)",
  async (reverse) => {
    const repls = makeBrowserRepls()
    const tabs = ["first", "second"]
    let created = 0
    let arrived = Promise.withResolvers<void>()
    type Request = {
      name: string
      args: Record<string, unknown>
      reply: ReturnType<typeof Promise.withResolvers<unknown>>
    }
    let pending: Request[] = []
    const values = new Map<string, string>()
    const cell = async (code: string) =>
      browserResultValue(
        await repls.execute("session", code, async (name, args) => {
          if (name === "tabs") {
            expect(args).toEqual({ action: "new" })
            return { tabs: [{ id: tabs[created++], selected: true }] }
          }
          const reply = Promise.withResolvers<unknown>()
          pending.push({ name, args, reply })
          if (pending.length === 2) arrived.resolve()
          return reply.promise
        })
      )
    const respond = ({ name, args }: Request): unknown => {
      const id = String(args.tabId)
      if (name === "tab_info") return { title: id === "first" ? "First" : "Second" }
      if (name === "playwright.fill") {
        values.set(id, String(args.value))
        return {}
      }
      if (name === "playwright.evaluate") return { value: values.get(id) }
      throw new Error(`Unexpected tool ${name}`)
    }
    const concurrent = async (code: string) => {
      pending = []
      arrived = Promise.withResolvers<void>()
      const operation = cell(code)
      await arrived.promise
      const requests = [...pending]
      for (const request of reverse ? requests.toReversed() : requests) {
        request.reply.resolve(respond(request))
      }
      const result = await operation
      return { result, requests: requests.map(({ name, args }) => ({ name, args })) }
    }
    try {
      await cell("var first = await browser.tabs.new()")
      await cell("var second = await browser.tabs.new()")
      const titles = await concurrent("await Promise.all([first.title(), second.title()])")
      expect(titles).toEqual({
        result: ["First", "Second"],
        requests: [
          { name: "tab_info", args: { tabId: "first" } },
          { name: "tab_info", args: { tabId: "second" } }
        ]
      })
      const filled = await concurrent(`await Promise.all([
      first.playwright.getByRole('textbox', {name:'Name',exact:true}).fill('left'),
      second.playwright.getByRole('textbox', {name:'Name',exact:true}).fill('right')
    ])`)
      expect(filled.requests).toEqual([
        {
          name: "playwright.fill",
          args: {
            tabId: "first",
            locator: { role: "textbox", name: "Name", exact: true },
            value: "left"
          }
        },
        {
          name: "playwright.fill",
          args: {
            tabId: "second",
            locator: { role: "textbox", name: "Name", exact: true },
            value: "right"
          }
        }
      ])
      const read = await concurrent(`await Promise.all([
      first.playwright.getByRole('textbox', {name:'Name',exact:true}).evaluate(e => e.value),
      second.playwright.getByRole('textbox', {name:'Name',exact:true}).evaluate(e => e.value)
    ])`)
      expect(read.result).toEqual(["left", "right"])
      expect(read.requests).toEqual(
        tabs.map((tabId) => ({
          name: "playwright.evaluate",
          args: {
            tabId,
            locator: { role: "textbox", name: "Name", exact: true },
            function: "e => e.value"
          }
        }))
      )
    } finally {
      for (const request of pending) request.reply.resolve({})
      await repls.close()
    }
  }
)

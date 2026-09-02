import { rmSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { makeBrowserUseProvider } from "./browser-use-provider.js"

const directories: string[] = []

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

describe("Browser Use pointer and tab lifecycle", () => {
  it(
    "composes held-button drags and held modifiers like Playwright's Mouse and Keyboard",
    { timeout: 60_000 },
    async () => {
      const directory = mkdtempSync(join(tmpdir(), "codevisor-browser-pointer-"))
      directories.push(directory)
      const previousHeadless = process.env.CODEVISOR_BROWSER_HEADLESS
      process.env.CODEVISOR_BROWSER_HEADLESS = "1"
      const provider = makeBrowserUseProvider(directory)
      try {
        if (provider.status().backend === "missing") return
        const context = { sessionId: "pointer-test", projectId: "pointer-test" }
        await provider.invoke(context, "use_backend", { backend: "managed" })
        const fixture = `<!doctype html><body style="margin:0"><script>
        window.events = [];
        for (const type of ["mousemove", "mousedown", "mouseup", "wheel"]) {
          addEventListener(type, (event) => events.push(type + ":" + event.buttons + ":" + event.clientX + "," + event.clientY));
        }
        for (const type of ["keydown", "keyup"]) {
          addEventListener(type, (event) => events.push(type + ":" + event.key + ":" + (event.shiftKey ? "shift" : "")));
        }
      </script></body>`
        await provider.invoke(context, "navigate", {
          url: `data:text/html,${encodeURIComponent(fixture)}`
        })
        const ok = async (tool: string, args: Readonly<Record<string, unknown>>) => {
          const result = await provider.invoke(context, tool, args)
          expect(result.isError, `${tool}: ${JSON.stringify(result.content)}`).not.toBe(true)
        }
        await ok("mouse_move", { x: 100, y: 100 })
        await ok("mouse_down", {})
        await ok("mouse_move", { x: 200, y: 150, steps: 4 })
        await ok("mouse_up", {})
        await ok("mouse_scroll", { deltaY: 40 })
        await ok("key_down", { key: "Shift" })
        await ok("press_key", { key: "a" })
        await ok("key_up", { key: "Shift" })
        await ok("keyboard_type", { text: "b", mode: "keys" })

        const events = await provider.invoke(context, "playwright.evaluate", {
          function: "() => window.events"
        })
        if (events.content[0]?.type !== "text") throw new Error("Missing events")
        expect((JSON.parse(events.content[0].text) as { value: string[] }).value).toEqual([
          "mousemove:0:100,100",
          "mousedown:1:100,100",
          "mousemove:1:125,112",
          "mousemove:1:150,125",
          "mousemove:1:175,137",
          "mousemove:1:200,150",
          "mouseup:0:200,150",
          "wheel:0:200,150",
          "keydown:Shift:shift",
          "keydown:A:shift",
          "keyup:A:shift",
          "keyup:Shift:",
          "keydown:b:",
          "keyup:b:"
        ])
      } finally {
        await provider.close()
        if (previousHeadless === undefined) delete process.env.CODEVISOR_BROWSER_HEADLESS
        else process.env.CODEVISOR_BROWSER_HEADLESS = previousHeadless
      }
    }
  )

  it("closes only unkept agent-created tabs on finalize and reports each outcome", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-browser-finalize-"))
    directories.push(directory)
    const previousHeadless = process.env.CODEVISOR_BROWSER_HEADLESS
    process.env.CODEVISOR_BROWSER_HEADLESS = "1"
    const provider = makeBrowserUseProvider(directory)
    try {
      if (provider.status().backend === "missing") return
      const context = { sessionId: "finalize-test", projectId: "finalize-test" }
      await provider.invoke(context, "use_backend", { backend: "managed" })
      const text = (result: Awaited<ReturnType<typeof provider.invoke>>): string => {
        const block = result.content[0]
        if (block?.type !== "text") throw new Error(JSON.stringify(result.content))
        return block.text
      }
      const tabIds = (result: Awaited<ReturnType<typeof provider.invoke>>): string[] =>
        (JSON.parse(text(result)) as { tabs: Array<{ id: string; selected: boolean }> }).tabs
          .filter((tab) => tab.selected)
          .map((tab) => tab.id)
      const [keptId] = tabIds(await provider.invoke(context, "tabs", { action: "new" }))
      const [scratchId] = tabIds(await provider.invoke(context, "tabs", { action: "new" }))
      expect(keptId).toBeDefined()
      expect(scratchId).toBeDefined()

      const finalized = await provider.invoke(context, "finalizeTabs", {
        native: true,
        keepIds: [keptId]
      })
      expect(JSON.parse(text(finalized))).toEqual({
        finalized: true,
        kept: [keptId],
        closed: [scratchId],
        released: []
      })

      // Chrome publishes a closed target's removal shortly after Target.closeTarget resolves.
      const deadline = Date.now() + 5_000
      let remaining: string[] = []
      do {
        remaining = (
          JSON.parse(text(await provider.invoke(context, "tabs", { action: "list" }))) as {
            tabs: Array<{ id: string }>
          }
        ).tabs.map((tab) => tab.id)
        if (!remaining.includes(scratchId!)) break
        await new Promise((resolve) => setTimeout(resolve, 50))
      } while (Date.now() < deadline)
      expect(remaining).toContain(keptId)
      expect(remaining).not.toContain(scratchId)
    } finally {
      await provider.close()
      if (previousHeadless === undefined) delete process.env.CODEVISOR_BROWSER_HEADLESS
      else process.env.CODEVISOR_BROWSER_HEADLESS = previousHeadless
    }
  })
})

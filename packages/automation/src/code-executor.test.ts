import { describe, expect, it } from "vitest"
import { CodeExecutionToolError, makeCodeExecutor, type CodeToolInvoker } from "./code-executor.js"

const unavailableTool: CodeToolInvoker = {
  invoke: async ({ path }) => {
    throw new Error(`Unexpected tool call: ${path}`)
  }
}

describe.sequential("Codevisor code executor", () => {
  it("executes TypeScript, lazy tool calls, logs, and emitted content", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async (): Promise<number> => {
        const response = await tools.browser.tabs({ window: "current" });
        console.log("tabs", response.count);
        emit({ type: "text", text: "visible output" });
        return response.count + 1;
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          return { count: 2 }
        }
      }
    )

    expect(result).toMatchObject({
      result: 3,
      logs: ["[log] tabs 2"],
      output: [{ type: "content", content: { type: "text", text: "visible output" } }]
    })
    expect(calls).toEqual([{ path: "browser.tabs", args: { window: "current" } }])
  })

  it("provides a native-shaped Playwright locator facade on tools.browser.tab", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async () => {
        const submit = tools.browser.tab.playwright.getByRole("button", {
          name: "Submit",
          exact: true
        });
        const count = await submit.count();
        await submit.click();
        return count;
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          if (call.path === "browser.playwright.count") return { count: 1 }
          return { delivered: true }
        }
      }
    )

    expect(result).toMatchObject({ result: 1 })
    expect(calls).toEqual([
      {
        path: "browser.playwright.count",
        args: { locator: { role: "button", name: "Submit", exact: true } }
      },
      {
        path: "browser.playwright.click",
        args: {
          locator: { role: "button", name: "Submit", exact: true },
          button: undefined,
          doubleClick: false,
          force: undefined,
          modifiers: undefined,
          timeoutMs: undefined
        }
      }
    ])
  })

  it("composes native-shaped locators, frames, evaluation, and tab capabilities", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async () => {
        const page = tools.browser.tab.playwright;
        const row = page.locator(".row").filter({
          hasText: "Ada",
          has: page.getByRole("button", { name: "Edit" }),
          visible: true
        }).first();
        const nested = row.getByText("Ada");
        const count = await nested.count();
        const frameText = await page.frameLocator("iframe").locator("p").allTextContents();
        const value = await nested.evaluate((element, suffix) => element.textContent + suffix, "!");
        const cdpCapability = await tools.browser.tab.capabilities.get("cdp");
        const cdp = await cdpCapability.send("Runtime.evaluate", {
          expression: "1 + 1"
        });
        return { count, frameText, value, cdp };
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          if (call.path === "browser.playwright.count") return { count: 1 }
          if (call.path === "browser.playwright.allTextContents") return { values: ["Frame"] }
          if (call.path === "browser.playwright.evaluate") return { value: "Ada!" }
          if (call.path === "browser.cdp.send") return { result: { result: { value: 2 } } }
          return {}
        }
      }
    )

    expect(result.error).toBeUndefined()
    expect(result.result).toEqual({
      count: 1,
      frameText: ["Frame"],
      value: "Ada!",
      cdp: { result: { value: 2 } }
    })
    expect(calls.find((call) => call.path === "browser.playwright.count")?.args).toEqual({
      locator: {
        text: "Ada",
        scope: {
          css: ".row",
          filters: {
            has: { role: "button", name: "Edit" },
            hasText: "Ada",
            visible: true
          },
          index: 0
        }
      }
    })
    expect(calls.find((call) => call.path === "browser.playwright.allTextContents")?.args).toEqual({
      locator: { css: "p", frame: ["iframe"] },
      timeoutMs: undefined
    })
  })

  it("provides native-shaped browser, tab lifecycle, and tab navigation facades", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async () => {
        const browser = tools.browser;
        await browser.nameSession("compatibility test");
        const tab = await browser.tabs.new();
        await tab.goto("https://example.com/");
        const title = await tab.title();
        await browser.tabs.finalize({ keep: [{ tab, status: "deliverable" }] });
        return { id: tab.id, title };
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          if (call.path === "browser.tabs" && (call.args as { action?: string }).action === "new") {
            return {
              tabs: [
                {
                  id: "tab-1",
                  index: 0,
                  selected: true,
                  title: "",
                  url: "about:blank"
                }
              ]
            }
          }
          if (call.path === "browser.tab_info") {
            return { id: "tab-1", title: "Example", url: "https://example.com/" }
          }
          return { delivered: true }
        }
      }
    )

    expect(result).toMatchObject({ result: { id: "tab-1", title: "Example" } })
    expect(calls).toEqual([
      { path: "browser.tabs", args: { action: "new" } },
      { path: "browser.tabs", args: { action: "select", id: "tab-1" } },
      { path: "browser.navigate", args: { url: "https://example.com/" } },
      { path: "browser.tabs", args: { action: "select", id: "tab-1" } },
      { path: "browser.tab_info", args: {} },
      {
        path: "browser.finalizeTabs",
        args: { native: true, keepIds: ["tab-1"] }
      }
    ])
  })

  it("does not charge time waiting for a host tool against the active execution budget", async () => {
    const startedAt = performance.now()
    const result = await makeCodeExecutor({ activeTimeoutMs: 100 }).execute(
      `async () => (await tools.browser.choose({})).answer`,
      {
        invoke: async () => {
          await new Promise((resolve) => setTimeout(resolve, 175))
          return { answer: "chrome" }
        }
      }
    )

    expect(performance.now() - startedAt).toBeGreaterThanOrEqual(150)
    expect(result).toMatchObject({ result: "chrome" })
    expect(result.error).toBeUndefined()
  })

  it("still interrupts code that exhausts its active execution budget", async () => {
    const result = await makeCodeExecutor({ activeTimeoutMs: 100 }).execute(
      `async () => { while (true) {} }`,
      unavailableTool
    )

    expect(result.error).toBe("QuickJS active execution timed out after 100ms")
  })

  it("lets sandbox code catch intentional tool errors without leaking defects", async () => {
    const visible = await makeCodeExecutor().execute(
      `async () => tools.browser.click({}).catch(error => error.message)`,
      {
        invoke: async () => {
          throw new CodeExecutionToolError("The click target is unavailable")
        }
      }
    )
    const hidden = await makeCodeExecutor().execute(
      `async () => tools.browser.click({}).catch(error => error.message)`,
      {
        invoke: async () => {
          throw new Error("secret internal detail")
        }
      }
    )

    expect(visible.result).toBe("The click target is unavailable")
    expect(hidden.result).toBe("Internal tool error")
  })

  it("cancels a suspended execution without waiting for its host tool", async () => {
    const controller = new AbortController()
    const execution = makeCodeExecutor().execute(
      `async () => tools.browser.choose({})`,
      { invoke: () => new Promise(() => undefined) },
      { signal: controller.signal }
    )
    setTimeout(() => controller.abort(), 20)

    await expect(execution).resolves.toMatchObject({
      error: "QuickJS execution was cancelled"
    })
  })

  it("does not expose Node or network globals", async () => {
    const result = await makeCodeExecutor().execute(
      `async () => ({
        process: typeof process,
        require: typeof require,
        fetch: (() => { try { fetch("https://example.com"); } catch (error) { return error.message; } })()
      })`,
      unavailableTool
    )

    expect(result.result).toEqual({
      process: "undefined",
      require: "undefined",
      fetch: "fetch is disabled in Codevisor code execution"
    })
  })
})

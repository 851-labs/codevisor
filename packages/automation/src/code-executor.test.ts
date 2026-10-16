import { describe, expect, it } from "vitest"

import { CodeExecutionToolError, makeCodeExecutor, type CodeToolInvoker } from "./code-executor.js"
import { recordOrEmpty } from "./unknown-values.js"

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

  it("calls the function however the model punctuates it", async () => {
    const executor = makeCodeExecutor()
    const results = await Promise.all(
      [
        "async () => 42",
        ";async () => 42",
        ";async () => {\n  return 42\n};",
        ";;(async () => 42)",
        "(async (): Promise<number> => 42) as () => Promise<number>;"
      ].map((code) => executor.execute(code, unavailableTool))
    )
    expect(results.map((result) => [result.result, result.error])).toEqual(
      Array.from({ length: 5 }, () => [42, undefined])
    )
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
          if (call.path === "browser.tabs" && recordOrEmpty(call.args).action === "new") {
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
      { path: "browser.nameSession", args: { name: "compatibility test" } },
      { path: "browser.tabs", args: { action: "new" } },
      { path: "browser.navigate", args: { tabId: "tab-1", url: "https://example.com/" } },
      { path: "browser.tab_info", args: { tabId: "tab-1" } },
      { path: "browser.markTab", args: { id: "tab-1", status: "deliverable" } },
      {
        path: "browser.finalizeTabs",
        args: { native: true, keepIds: ["tab-1"] }
      }
    ])
  })

  it("does not charge time waiting for a host tool against the active execution budget", async () => {
    let now = 0
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const execution = makeCodeExecutor({ activeTimeoutMs: 1000, now: () => now }).execute(
      `async () => (await tools.browser.choose({})).answer`,
      {
        invoke: async () => {
          entered.resolve()
          await release.promise
          return { answer: "chrome" }
        }
      }
    )
    await entered.promise
    now += 60_000
    release.resolve()
    const result = await execution

    expect(result).toMatchObject({ result: "chrome" })
    expect(result.error).toBeUndefined()
  })

  it("still interrupts code that exhausts its active execution budget", async () => {
    let now = 0
    const result = await makeCodeExecutor({ activeTimeoutMs: 100, now: () => now++ }).execute(
      `async () => { while (true) {} }`,
      unavailableTool
    )

    expect(result.error).toBe(
      "Script used its 100ms CPU budget for running JavaScript (time spent waiting on tools does not count); check for an infinite loop"
    )
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

  it("reports an uncaught tool error without the host's stack frames", async () => {
    const result = await makeCodeExecutor().execute(`async () => tools.computer.click({})`, {
      invoke: async () => {
        throw new CodeExecutionToolError("That element is gone or changed")
      }
    })

    expect(result.error).toBe("That element is gone or changed")
  })

  it("cancels a suspended execution without waiting for its host tool", async () => {
    const controller = new AbortController()
    const entered = Promise.withResolvers<void>()
    const execution = makeCodeExecutor().execute(
      `async () => tools.browser.choose({})`,
      {
        invoke: () => {
          entered.resolve()
          return new Promise(() => undefined)
        }
      },
      { signal: controller.signal }
    )
    await entered.promise
    controller.abort()

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

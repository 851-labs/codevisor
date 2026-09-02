import { describe, expect, it } from "vitest"
import { makeCodeExecutor } from "./code-executor.js"

describe.sequential("Codevisor browser facade", () => {
  it("exposes Playwright-shaped page mouse and keyboard on tab.playwright", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async () => {
        const tab = await tools.browser.tabs.new();
        const { mouse, keyboard } = tab.playwright;
        await keyboard.press("r");
        await mouse.move(300, 300);
        await mouse.down();
        await mouse.move(500, 450, { steps: 10 });
        await mouse.up();
        await mouse.click(10, 20, { button: "right" });
        await mouse.dblclick(30, 40);
        await mouse.wheel(0, 120);
        await keyboard.down("Shift");
        await keyboard.type("ab");
        await keyboard.up("Shift");
        await keyboard.insertText("raw");
        return "ok";
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          if (call.path === "browser.tabs") {
            return {
              tabs: [{ id: "tab-1", index: 0, selected: true, title: "", url: "about:blank" }]
            }
          }
          return {}
        }
      }
    )
    expect(result).toMatchObject({ result: "ok" })
    const actions = calls.filter((call) => call.path !== "browser.tabs")
    expect(actions).toEqual([
      { path: "browser.press_key", args: { key: "r" } },
      { path: "browser.mouse_move", args: { x: 300, y: 300 } },
      { path: "browser.mouse_down", args: { button: "left" } },
      { path: "browser.mouse_move", args: { x: 500, y: 450, steps: 10 } },
      { path: "browser.mouse_up", args: { button: "left" } },
      { path: "browser.mouse_click", args: { x: 10, y: 20, button: "right", doubleClick: false } },
      { path: "browser.mouse_click", args: { x: 30, y: 40, button: "left", doubleClick: true } },
      { path: "browser.mouse_scroll", args: { deltaX: 0, deltaY: 120 } },
      { path: "browser.key_down", args: { key: "Shift" } },
      { path: "browser.keyboard_type", args: { text: "ab", mode: "keys" } },
      { path: "browser.key_up", args: { key: "Shift" } },
      { path: "browser.keyboard_type", args: { text: "raw" } }
    ])
  })

  it("returns usable tab objects from tabs.list and names unsupported members", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async () => {
        const browser = tools.browser;
        const tabs = await browser.tabs.list({ scope: "session" });
        const tab = tabs.find((candidate) => candidate.info.url.includes("excalidraw"));
        await tab.playwright.mouse.move(1, 2);
        const errors = [];
        for (const probe of [
          () => tab.playwright.frameLocator("iframe").mouse,
          () => tab.cua.hover,
          () => tab.nothing
        ]) {
          try { probe(); errors.push("no error"); } catch (error) { errors.push(error.message); }
        }
        return { id: tab.id, origin: tab.info.origin, hasPlaywright: !!tab.playwright, errors };
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          if (
            call.path === "browser.tabs" &&
            (call.args as { action?: string }).action === "list"
          ) {
            return {
              tabs: [
                {
                  id: "tab-1",
                  index: 0,
                  selected: false,
                  title: "Slack",
                  url: "https://slack.com/"
                },
                {
                  id: "tab-2",
                  index: 1,
                  selected: true,
                  title: "Excalidraw",
                  url: "https://excalidraw.com/",
                  origin: "created"
                }
              ]
            }
          }
          return {}
        }
      }
    )
    expect(result).toMatchObject({
      result: {
        id: "tab-2",
        origin: "created",
        hasPlaywright: true,
        errors: [
          expect.stringContaining("frameLocator.mouse is not supported"),
          expect.stringContaining(
            "tab.cua.hover is not supported by Codevisor Browser; available: click"
          ),
          expect.stringContaining("tab.nothing is not supported")
        ]
      }
    })
    expect(calls).toEqual([
      { path: "browser.tabs", args: { action: "list", scope: "session" } },
      { path: "browser.tabs", args: { action: "select", id: "tab-2" } },
      { path: "browser.mouse_move", args: { x: 1, y: 2 } }
    ])
  })

  it("exposes Chrome tab groups through browser.tabGroups", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async () => {
        const browser = tools.browser;
        const [docs, issue] = await browser.tabs.list();
        const group = await browser.tabGroups.ensure({ tabs: [docs, issue], title: "Research", color: "blue" });
        await browser.tabGroups.add(group, ["13"]);
        await browser.tabGroups.update(group.id, { collapsed: true });
        const groups = await browser.tabGroups.list();
        await browser.tabGroups.ungroup([issue]);
        const errors = [];
        for (const probe of [
          () => browser.tabGroups.create({ tabs: [] }),
          () => browser.tabGroups.create({ tabs: [{}] }),
          () => browser.tabGroups.update("seven", {}),
          () => browser.tabGroups.rename
        ]) {
          try { probe(); errors.push("no error"); } catch (error) { errors.push(error.message); }
        }
        return { groupId: group.id, docsGroup: docs.info.groupId, groups, errors };
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          if (call.path === "browser.tabs") {
            return {
              tabs: [
                {
                  id: "11",
                  index: 0,
                  selected: true,
                  title: "Docs",
                  url: "https://a.test/",
                  groupId: 7
                },
                { id: "12", index: 1, selected: false, title: "Issue", url: "https://b.test/" }
              ]
            }
          }
          const action = (call.args as { action: string }).action
          if (action === "ensure") return { group: { id: 7, title: "Research" }, created: true }
          if (action === "list")
            return { groups: [{ id: 7, title: "Research", tabIds: ["11", "12", "13"] }] }
          if (action === "ungroup") return { ungrouped: ["12"] }
          return {
            group: { id: 7, title: "Research", color: "blue", collapsed: action === "update" }
          }
        }
      }
    )
    expect(result).toMatchObject({
      result: {
        groupId: 7,
        docsGroup: 7,
        groups: [{ id: 7, tabIds: ["11", "12", "13"] }],
        errors: [
          "tabGroups expects a non-empty array of tabs or tab ids",
          "tabGroups tabs[0] must be a tab or a tab id",
          "tabGroups expects a group returned by tabGroups or its numeric id",
          expect.stringContaining("browser.tabGroups.rename is not supported")
        ]
      }
    })
    expect(
      calls.filter((call) => call.path === "browser.tab_groups").map((call) => call.args)
    ).toEqual([
      { action: "ensure", tabIds: ["11", "12"], title: "Research", color: "blue" },
      { action: "add", groupId: 7, tabIds: ["13"] },
      { action: "update", groupId: 7, collapsed: true },
      { action: "list" },
      { action: "ungroup", tabIds: ["12"] }
    ])
  })

  it("keeps a bare tab or tab id passed to tabs.finalize and reports the outcome", async () => {
    const calls: Array<{ readonly path: string; readonly args: unknown }> = []
    const result = await makeCodeExecutor().execute(
      `async () => {
        const browser = tools.browser;
        const tab = await browser.tabs.new();
        return browser.tabs.finalize({ keep: [tab, "tab-9"] });
      }`,
      {
        invoke: async (call) => {
          calls.push(call)
          if (call.path === "browser.tabs") {
            return {
              tabs: [{ id: "tab-1", index: 0, selected: true, title: "", url: "about:blank" }]
            }
          }
          if (call.path === "browser.finalizeTabs") {
            return { finalized: true, kept: ["tab-1", "tab-9"], closed: ["tab-2"], released: [] }
          }
          return {}
        }
      }
    )

    expect(result).toMatchObject({
      result: { kept: ["tab-1", "tab-9"], closed: ["tab-2"], released: [] }
    })
    expect(calls.map((call) => call.path)).toEqual(["browser.tabs", "browser.finalizeTabs"])
    expect(calls[1]).toEqual({
      path: "browser.finalizeTabs",
      args: { native: true, keepIds: ["tab-1", "tab-9"] }
    })
  })

  it("rejects tabs.finalize keep entries it cannot resolve instead of closing tabs", async () => {
    const calls: string[] = []
    for (const [keep, message] of [
      ["[{}]", "keep[0] must be a tab, a tab id, or { tab, status }"],
      ["[{ tab: {} }]", "keep[0] must be a tab, a tab id, or { tab, status }"],
      ["[{ tab: 'tab-1', status: 'later' }]", "keep[0].status must be deliverable or handoff"],
      ["'tab-1'", "keep must be an array"]
    ] as const) {
      const result = await makeCodeExecutor().execute(
        `async () => tools.browser.tabs.finalize({ keep: ${keep} })`,
        {
          invoke: async (call) => {
            calls.push(call.path)
            return {}
          }
        }
      )
      expect(result, keep).toMatchObject({ error: expect.stringContaining(message) })
    }
    expect(calls).toEqual([])
  })
})

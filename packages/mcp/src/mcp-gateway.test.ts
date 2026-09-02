import { describe, expect, it } from "vitest"
import { browserSessionTabsNotice } from "./mcp-gateway.js"

describe("browserSessionTabsNotice", () => {
  it("lists only tabs the session created so a retry reuses them", () => {
    expect(
      browserSessionTabsNotice([
        { id: "t1", url: "https://excalidraw.com/", origin: "created" },
        { id: "t2", url: "https://slack.com/", origin: "claimed" },
        { id: "t3", origin: "created" }
      ])
    ).toBe(
      "\n\nBrowser Use tabs this session opened are still open. Reuse one with " +
        "browser.tabs.get(id) instead of calling browser.tabs.new() again:\n" +
        "- t1 https://excalidraw.com/\n- t3"
    )
  })

  it("stays silent when the session opened nothing", () => {
    expect(browserSessionTabsNotice([])).toBe("")
    expect(browserSessionTabsNotice([{ id: "t2", origin: "claimed" }])).toBe("")
  })
})

import { mkdtempSync, rmSync } from "node:fs"
import { symlink, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it } from "vitest"

import { APP_VIEW_RETENTION_MS, makePluginAppViewStore } from "./mcp-plugin-app-views.js"
import {
  appResourceUri,
  cappedToolResult,
  capturedAppView,
  toolVisibleTo,
  type PluginAppView
} from "./mcp-plugin-apps.js"

const directories: Array<string> = []
afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

const tool = (meta?: Record<string, unknown>): Tool => ({
  name: "show_alerts",
  inputSchema: { type: "object" },
  ...(meta === undefined ? {} : { _meta: meta })
})

const view: PluginAppView = {
  viewId: "0b9a8f8e-5d1c-4f43-9f53-3e1c2c7f2a10",
  machineId: "studio",
  sessionId: "session-1",
  serverId: "grafana",
  serverName: "Grafana",
  toolName: "show_alerts",
  resourceUri: "ui://grafana/alerts.html",
  accountId: "work",
  toolInput: { range: "1h" },
  toolResult: { content: [{ type: "text", text: "2 alerts" }] },
  createdAt: "2026-10-27T12:00:00.000Z"
}

const storeIn = () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-app-views-"))
  directories.push(directory)
  return { directory, now: Date.parse("2026-10-27T12:00:00.000Z") }
}

describe("app tools", () => {
  it("reads the UI resource from current and legacy tool metadata", () => {
    expect(appResourceUri(tool({ ui: { resourceUri: "ui://grafana/alerts.html" } }))).toBe(
      "ui://grafana/alerts.html"
    )
    expect(appResourceUri(tool({ "ui/resourceUri": "ui://grafana/legacy.html" }))).toBe(
      "ui://grafana/legacy.html"
    )
    expect(appResourceUri(tool({ "openai/outputTemplate": "ui://widget/zillow-areas.html" }))).toBe(
      "ui://widget/zillow-areas.html"
    )
    expect(
      appResourceUri(
        tool({
          ui: { resourceUri: "ui://widget/new.html" },
          "openai/outputTemplate": "ui://widget/old.html"
        })
      )
    ).toBe("ui://widget/new.html")
    expect(appResourceUri(tool({ ui: { resourceUri: "https://grafana.example/x" } }))).toBe(
      undefined
    )
    expect(appResourceUri(tool())).toBeUndefined()
  })

  it("lets the model and the app see tools by their declared visibility", () => {
    expect(toolVisibleTo(tool(), "model")).toBe(true)
    expect(toolVisibleTo(tool({ ui: { visibility: ["app"] } }), "model")).toBe(false)
    expect(toolVisibleTo(tool({ ui: { visibility: ["app"] } }), "app")).toBe(true)
  })

  it("keeps a capped result's widget data first, then structured content, then text", () => {
    const small = { content: [{ type: "text" as const, text: "ok" }], structuredContent: { n: 1 } }
    const widget = { "zillow.com/data": { payload: "w".repeat(60) } }
    const result = {
      content: [
        { type: "text" as const, text: "t".repeat(60) },
        { type: "text" as const, text: "kept" }
      ],
      structuredContent: { results: "s".repeat(60) },
      isError: true,
      _meta: widget
    }

    expect(cappedToolResult(small, 1_000)).toBe(small)
    expect(cappedToolResult(result, 220)).toEqual({
      content: [{ type: "text", text: "kept" }],
      structuredContent: { results: "s".repeat(60) },
      isError: true,
      _meta: { ...widget, "dev.codevisor/truncated": true }
    })
    expect(cappedToolResult(result, 130)).toEqual({
      content: [{ type: "text", text: "kept" }],
      isError: true,
      _meta: { ...widget, "dev.codevisor/truncated": true }
    })
    expect(cappedToolResult(result, 50)).toEqual({
      content: [{ type: "text", text: "kept" }],
      isError: true,
      _meta: { "dev.codevisor/truncated": true }
    })
    expect(cappedToolResult({ content: [{ type: "text", text: "x".repeat(80) }] }, 50)).toEqual({
      content: [],
      _meta: { "dev.codevisor/truncated": true }
    })
  })

  it("captures views only for app tools called from a session", () => {
    const capture = {
      viewId: view.viewId,
      machineId: "studio",
      sessionId: "session-1",
      server: { id: "grafana", name: "Grafana" },
      tool: tool({ ui: { resourceUri: "ui://grafana/alerts.html" } }),
      accountId: undefined,
      toolInput: {},
      toolResult: { content: [] },
      createdAt: view.createdAt
    }

    expect(capturedAppView(capture)).not.toHaveProperty("accountId")
    expect(capturedAppView({ ...capture, sessionId: undefined })).toBeUndefined()
    expect(capturedAppView({ ...capture, tool: undefined })).toBeUndefined()
  })
})

describe("app view store", () => {
  it("saves views and reads them back by id", async () => {
    const { directory } = storeIn()
    const store = makePluginAppViewStore(directory)

    await store.save(view)

    expect(await store.get(view.viewId)).toEqual(view)
    expect(await store.get("../../etc/passwd")).toBeUndefined()
    expect(await store.get("1b9a8f8e-5d1c-4f43-9f53-3e1c2c7f2a10")).toBeUndefined()
  })

  it("ignores files that aren't views", async () => {
    const { directory } = storeIn()
    const store = makePluginAppViewStore(directory)
    await store.save(view)
    await writeFile(join(directory, "plugin-app-views", `${view.viewId}.json`), "{")

    expect(await store.get(view.viewId)).toBeUndefined()
  })

  it("prunes views older than the retention window", async () => {
    const { directory, now } = storeIn()
    const store = makePluginAppViewStore(directory, () => now)
    const fresh = { ...view, viewId: "2b9a8f8e-5d1c-4f43-9f53-3e1c2c7f2a10" }
    await store.prune()
    await store.save(view)
    await store.save(fresh)
    const old = new Date(now - APP_VIEW_RETENTION_MS - 1)
    await utimes(join(directory, "plugin-app-views", `${view.viewId}.json`), old, old)
    const recent = new Date(now)
    await utimes(join(directory, "plugin-app-views", `${fresh.viewId}.json`), recent, recent)

    await symlink(join(directory, "missing.json"), join(directory, "plugin-app-views", "dangling"))

    await store.prune()

    expect(await store.get(view.viewId)).toBeUndefined()
    expect(await store.get(fresh.viewId)).toEqual(fresh)
  })
})

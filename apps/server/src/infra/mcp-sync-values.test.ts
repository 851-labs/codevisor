import { describe, expect, it } from "vitest"

import { mcpCreation, parseSyncedValue, syncedValue } from "./mcp-sync-values.js"

const grafana = {
  id: "server-1",
  name: "Grafana",
  kind: "managed",
  catalogId: "dev.codevisor/grafana",
  catalogVersion: "1.0.0",
  transport: "stdio" as const,
  command: "codevisor-plugin",
  args: ["dev.codevisor/grafana"],
  enabled: true,
  authType: "none" as const
}

describe("synced plugin values", () => {
  it("carries the catalog id and version to another Mac", () => {
    const value = syncedValue(grafana, {})
    expect(value).toMatchObject({ catalogId: "dev.codevisor/grafana", catalogVersion: "1.0.0" })
    expect(parseSyncedValue(JSON.parse(JSON.stringify(value)))).toEqual(value)
    expect(mcpCreation(value)).toMatchObject({
      catalogId: "dev.codevisor/grafana",
      catalogVersion: "1.0.0"
    })
  })

  it("ignores catalog fields that aren't strings", () => {
    const parsed = parseSyncedValue({
      ...syncedValue(grafana, {}),
      catalogId: 3,
      catalogVersion: null
    })
    expect(parsed).not.toHaveProperty("catalogId")
    expect(parsed).not.toHaveProperty("catalogVersion")
    expect(mcpCreation(parsed!)).not.toHaveProperty("catalogVersion")
  })
})

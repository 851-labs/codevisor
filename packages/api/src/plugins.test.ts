import { describe, expect, it } from "vitest"
import {
  ApplyPluginUpdateRequest,
  PluginUpdatePlan,
  PluginUpdatesResponse,
  decode
} from "./index.js"

describe("plugin update API", () => {
  it("validates explicit states and prepared plans", () => {
    expect(
      decode(PluginUpdatesResponse)({
        updates: [
          {
            checkedAt: "2026-08-23T00:00:00.000Z",
            installedVersion: "1.0.0",
            pluginId: "owner.example",
            registryVersion: "2.0.0",
            state: "available"
          }
        ]
      }).updates[0]?.state
    ).toBe("available")
    expect(decode(ApplyPluginUpdateRequest)({ planId: "plan-1" })).toEqual({ planId: "plan-1" })
    expect(
      decode(PluginUpdatePlan)({
        candidate: {
          panes: [],
          runCommand: "node server.js",
          setupCommands: ["npm ci"],
          version: "2.0.0"
        },
        current: {
          panes: [],
          runCommand: "node server.js",
          setupCommands: [],
          version: "1.0.0"
        },
        expiresAt: "2026-08-23T00:15:00.000Z",
        name: "Example",
        paneChanges: { added: [], changed: [], removed: [] },
        planId: "plan-1",
        pluginId: "owner.example",
        resolvedCommit: "a".repeat(40),
        toolChanges: { added: [], changed: [], removed: [] }
      }).candidate.version
    ).toBe("2.0.0")
  })
})

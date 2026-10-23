import { describe, expect, it } from "vitest"

import { apiTool } from "./codevisor-api-tool-spec.js"
import { shapedToolResult } from "./codevisor-tool-shapes.js"

const shaped = (path: string, body: unknown): unknown =>
  shapedToolResult(apiTool("fixture.tool", "", "GET", path), body)

describe("Codevisor tool result shapes", () => {
  it("wraps every list as items and names each record's id after its resource", () => {
    expect(shaped("/v1/projects", [{ id: "p1", name: "web" }])).toEqual({
      items: [{ projectId: "p1", name: "web" }]
    })
    expect(shaped("/v1/machines", { machines: [{ id: "m1", name: "Studio" }] })).toEqual({
      items: [{ machineId: "m1", name: "Studio" }]
    })
    expect(shaped("/v1/skills", { dir: "/skills", skills: [{ name: "a" }] })).toEqual({
      dir: "/skills",
      items: [{ name: "a" }]
    })
    expect(shaped("/v1/sessions/:id/queue", [{ id: "q1", sessionId: "s1" }])).toEqual({
      items: [{ queueId: "q1", agentId: "s1" }]
    })
  })

  it("names ephemeral machine ids after their resource in lists and single records", () => {
    expect(shaped("/v1/ephemeral-machines", [{ id: "e1", state: "ready" }])).toEqual({
      items: [{ ephemeralMachineId: "e1", state: "ready" }]
    })
    expect(shaped("/v1/ephemeral-machines", { id: "e2", state: "creating" })).toEqual({
      ephemeralMachineId: "e2",
      state: "creating"
    })
  })

  it("calls sessions agents everywhere in a result, however deeply nested", () => {
    expect(
      shaped("/v1/sessions/:id", {
        id: "s1",
        parentSessionId: "parent",
        viewing: { sessionId: "s2", page: "home" },
        subscriptions: [{ targetSessionId: "s3" }]
      })
    ).toEqual({
      agentId: "s1",
      parentAgentId: "parent",
      viewing: { agentId: "s2", page: "home" },
      subscriptions: [{ agentId: "s3" }]
    })
  })

  it("leaves unknown resources, scalars, and non-list objects alone", () => {
    expect(shaped("/v1/health", { id: "kept", ok: true })).toEqual({ id: "kept", ok: true })
    expect(shaped("/v1/health", "plain")).toBe("plain")
    expect(shaped("/v1/machines", { machines: "not a list" })).toEqual({ machines: "not a list" })
    expect(shaped("/", [1, 2])).toEqual({ items: [1, 2] })
    expect(shaped("/", { id: "root" })).toEqual({ id: "root" })
  })
})

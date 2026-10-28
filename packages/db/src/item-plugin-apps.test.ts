import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const app = (viewId: string) => ({
  viewId,
  machineId: "machine-1",
  serverId: "zillow",
  serverName: "Zillow",
  toolName: "search",
  resourceUri: "ui://widget/search.html"
})

const execute = (
  toolCallId: string,
  status: string,
  execution: Record<string, unknown>
): Record<string, unknown> => ({
  sessionUpdate: "tool_call_update",
  toolCallId,
  title: "execute",
  kind: "execute",
  status,
  _meta: { codevisorExecution: { calls: [], ...execution } }
})

describe("plugin apps on transcript items", () => {
  it("lists each completed app view once, so collapsed turns still show their apps", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/plugin-apps" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const output = (payload: Record<string, unknown>) =>
        run(db.appendEvent("session.output", session.id, payload))
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      await output(
        execute("a", "completed", { state: "completed", apps: [app("v1"), { viewId: "bad" }] })
      )
      await output(execute("b", "completed", { state: "completed", apps: [app("v1"), app("v2")] }))
      await output(execute("c", "completed", { state: "failed", apps: [app("v3")] }))
      await output(execute("d", "in_progress", { state: "running", apps: [app("v4")] }))
      await output(execute("e", "completed", { state: "completed" }))
      await output({
        sessionUpdate: "tool_call_update",
        toolCallId: "f",
        status: "completed",
        rawInput: { codevisorExecution: "mentioned", apps: [app("v5")] }
      })
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))

      expect(page.items.map((item) => item.apps?.map((view) => view.viewId))).toEqual([
        ["v1", "v2"]
      ])
    } finally {
      await run(db.close)
    }
  })
})

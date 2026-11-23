import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { turnUsageObserved } from "@codevisor/agent-runtime"
import { expect, it } from "vitest"

import { makeEventFanout } from "../server.js"
import { makeServices, run, tempDirs } from "../test-support.js"
import { sessionEventSink } from "./session-events.js"

it("adds each turn's token usage to the chat's totals, keeping its context reading", async () => {
  const { services } = await makeServices("turn-usage")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-turn-usage-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const session = await run(services.db.createSession({ projectId: project.id, harnessId: "kilo" }))
  const sink = sessionEventSink(services, await run(makeEventFanout), "turn-usage", session.id)

  await sink({
    kind: "session.updated",
    subjectId: session.id,
    payload: { sessionUpdate: "usage_update", used: 5000, size: 131_072 }
  })
  await sink(
    turnUsageObserved(session.id, { inputTokens: 1000, outputTokens: 50, totalTokens: 1050 })
  )
  await sink(
    turnUsageObserved(session.id, {
      inputTokens: 2000,
      outputTokens: 70,
      totalTokens: 2070,
      cachedInputTokens: 800
    })
  )

  const summary = await run(services.db.getSessionSummary(session.id))
  expect(summary.usage).toMatchObject({
    used: 5000,
    size: 131_072,
    inputTokens: 3000,
    outputTokens: 120,
    totalTokens: 3120,
    cachedInputTokens: 800
  })
})

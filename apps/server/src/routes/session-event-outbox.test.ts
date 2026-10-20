import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it } from "vitest"

import { makeEventFanout } from "../server-context.js"
import { idleRouteState, makeServices, run, tempDirs } from "../test-support.js"
import { makeSessionEventOutbox } from "./session-event-outbox.js"

it("wakes no one with an event that went stale before it could be delivered", async () => {
  const { services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-event-outbox-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const caller = await run(services.db.createSession({ projectId: project.id, harnessId: "codex" }))
  const outbox = makeSessionEventOutbox(
    services,
    await run(makeEventFanout),
    idleRouteState(),
    "server-a"
  )

  await outbox.deliver(caller.id, {
    message: { key: "job:collected", text: "The job the caller already collected finished" },
    sourceSessionId: caller.id,
    stale: () => true
  })

  expect(outbox.wokenBy(caller.id)).toEqual(new Set())
  expect(await run(services.db.listPromptQueue(caller.id))).toEqual([])
})

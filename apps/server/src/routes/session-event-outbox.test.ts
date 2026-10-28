import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it } from "vitest"

import { makeEventFanout } from "../server-context.js"
import { idleRouteState, makeServices, run, tempDirs } from "../test-support.js"
import { makeSessionEventOutbox } from "./session-event-outbox.js"

it("queues every event for a busy subscriber in order, replacing none", async () => {
  const { services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-event-outbox-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const create = () => run(services.db.createSession({ projectId: project.id, harnessId: "codex" }))
  const [subscriber, worker] = [await create(), await create()]
  const routeState = idleRouteState()
  routeState.activeTurnSessions.add(subscriber.id)
  const outbox = makeSessionEventOutbox(
    services,
    await run(makeEventFanout),
    routeState,
    "server-a"
  )

  for (const text of ["first turn ended", "second turn ended"]) {
    await outbox.deliver(subscriber.id, { message: { text }, sourceSessionId: worker.id })
  }

  expect(
    (await run(services.db.listPromptQueue(subscriber.id))).map((item) => [item.text, item.origin])
  ).toEqual([
    ["first turn ended", "system"],
    ["second turn ended", "system"]
  ])
  expect(outbox.wokenBy(subscriber.id)).toEqual(new Set([worker.id]))
})

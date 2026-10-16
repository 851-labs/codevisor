import Database from "better-sqlite3"
import { Effect } from "effect"
import { expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

it("drops the hidden terminal tabs clients made for agent background commands", async () => {
  const filename = tempDatabase()
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  const project = await run(db.createProject({ folderPath: "/tmp/agent-terminals" }))
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name: "agents", hasCustomName: false })
  )
  for (const [id, resourceId, metadata] of [
    ["agent-pane", "chat-1:bg:tool-1", '{"attachOnly":true,"ownerChatSessionId":"chat-1"}'],
    ["user-pane", "user-shell", '{"attachOnly":false}']
  ] as const) {
    await run(
      db.upsertWorkspacePane(workspace.id, {
        id,
        providerId: "codevisor",
        paneType: "terminal",
        title: id,
        resourceKind: "terminal",
        resourceId,
        metadata
      })
    )
  }
  await Effect.runPromise(db.close)
  const legacy = new Database(filename)
  try {
    legacy.exec("delete from schema_migrations where id = 60")
  } finally {
    legacy.close()
  }

  const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
  expect((await run(upgraded.listWorkspacePanes)).map((pane) => pane.id)).toEqual(["user-pane"])
  await Effect.runPromise(upgraded.close)
})

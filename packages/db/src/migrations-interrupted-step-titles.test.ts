import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { rewindInterruptedStepTitlesSql, run, tempDatabase } from "./test-support.js"

const leakedTitle = "[Your previous step was interrupted because this message arrived mid-step…"

const seedChat = async (
  db: CodevisorDatabaseService,
  id: string,
  prompts: ReadonlyArray<string>
): Promise<void> => {
  const project = await run(db.createProject({ folderPath: `/tmp/${id}` }))
  await run(db.createSession({ id, projectId: project.id, harnessId: "claude", title: "New Chat" }))
  for (const [index, prompt] of prompts.entries()) {
    await run(db.appendConversationItem(id, "user", `${id}-${index}`, prompt, false))
  }
}

const rewind = (filename: string, statements: string): void => {
  const sqlite = new Database(filename)
  try {
    sqlite.exec(statements)
  } finally {
    sqlite.close()
  }
}

describe("interrupted-step title repair", () => {
  it("retitles chats named after the note by their latest prompt and leaves the rest alone", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    await seedChat(db, "steered", ["run the checks", "do this\ninstead"])
    await seedChat(db, "long", ["x".repeat(250)])
    await seedChat(db, "empty", [])
    await seedChat(db, "renamed", ["run the checks"])
    await seedChat(db, "titled", ["run the checks"])
    await run(db.close)
    rewind(
      filename,
      `${rewindInterruptedStepTitlesSql}
       update sessions set title = '${leakedTitle}' where id <> 'titled';
       update sessions set title = 'Fix the checks' where id = 'titled';
       update sessions set title_is_user_set = 1 where id = 'renamed';`
    )

    const upgraded = await run(makeDatabase({ filename, serverId: "machine-a" }))
    onTestFinished(() => run(upgraded.close))
    const title = async (id: string) => (await run(upgraded.getSessionSummary(id))).title

    expect(await title("steered")).toBe("do this instead")
    expect(await title("long")).toBe(`${"x".repeat(200)}…`)
    expect(await title("empty")).toBe("New Chat")
    expect(await title("renamed")).toBe(leakedTitle)
    expect(await title("titled")).toBe("Fix the checks")
  })
})

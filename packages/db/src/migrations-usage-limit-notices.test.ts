import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const limitedChat = "00000000-0000-4000-8000-000000000001"
const otherChat = "00000000-0000-4000-8000-000000000002"
const fiveHourLimit = "You've hit your 5-hour limit · resets 8:10pm (America/Los_Angeles)"

const open = async (filename: string): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const seedV80 = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  const project = await run(db.createProject({ folderPath: "/tmp/notices-repo", name: "repo" }))
  for (const id of [limitedChat, otherChat]) {
    await run(
      db.createWorkspaceWithSession({
        workspace: { id: `ws-${id}`, projectId: project.id, name: id, hasCustomName: false },
        session: { id, projectId: project.id, harnessId: "claude-code", title: id }
      })
    )
    await run(
      db.createBot({
        id: `bot-${id}`,
        name: id,
        symbolName: "sparkles",
        mascot: { color: "mint", hat: "none", eyewear: "none" },
        slug: id,
        projectId: project.id,
        sessionId: id,
        workspaceId: `ws-${id}`,
        projects: []
      })
    )
  }
  const notices: ReadonlyArray<[string, "user" | "notice", string]> = [
    [limitedChat, "user", "Summarize today's PRs"],
    [limitedChat, "notice", fiveHourLimit],
    [limitedChat, "notice", "Refused"],
    [limitedChat, "user", fiveHourLimit],
    [otherChat, "notice", fiveHourLimit]
  ]
  for (const [sessionId, sender, text] of notices) {
    await run(db.appendBotMessage(sessionId, { sender, text }))
  }
  await run(db.close)
  const sqlite = new Database(filename)
  try {
    const insertStop = sqlite.prepare(
      `insert into chat_items (id, session_id, position, role, status, created_at, updated_at, stop_detail, stop_kind)
       values (?, ?, ?, 'assistant', 'complete', '2026-10-27T00:00:00.000Z', '2026-10-27T00:00:00.000Z', ?, ?)`
    )
    insertStop.run("limited-stop", limitedChat, 0, fiveHourLimit, "usageLimit")
    insertStop.run("refused-stop", limitedChat, 1, "Refused", null)
    insertStop.run("other-stop", otherChat, 0, fiveHourLimit, null)
    sqlite.exec(beforeConversationsSql)
    sqlite.exec("delete from schema_migrations where id in (81, 104)")
  } finally {
    sqlite.close()
  }
}

const beforeConversationsSql = `
  create table bot_messages (
    id text primary key,
    session_id text not null references sessions(id) on delete cascade,
    sequence integer not null,
    sender text not null,
    text text not null,
    attachments text,
    created_at text not null
  );
  create unique index bot_messages_session_sequence_idx on bot_messages(session_id, sequence);
  insert into bot_messages (id, session_id, sequence, sender, text, attachments, created_at)
    select m.id, bots.session_id, m.sequence,
      coalesce((select kind from conversation_participants p where p.id = m.sender_id), 'notice'),
      m.text, m.attachments, m.created_at
    from conversation_messages m join bots on bots.conversation_id = m.conversation_id;
  drop table conversation_messages;
  drop table conversation_participants;
  drop index bots_session_idx;
  alter table bots drop column conversation_id;
  drop table conversations;
`

const conversation = async (db: CodevisorDatabaseService, sessionId: string) =>
  (await run(db.listBotMessages(sessionId, undefined, 10))).messages.map((message) => [
    message.sender,
    message.text
  ])

describe("usage-limit bot notice upgrade", () => {
  it("drops notices that repeat a chat's usage-limit stop and keeps every other message through the move into conversations", async () => {
    const filename = tempDatabase()
    await seedV80(filename)

    const db = await open(filename)

    expect(await conversation(db, limitedChat)).toEqual([
      ["user", "Summarize today's PRs"],
      ["notice", "Refused"],
      ["user", fiveHourLimit]
    ])
    expect(await conversation(db, otherChat)).toEqual([["notice", fiveHourLimit]])
  })
})

import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService, type ThreadParty } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const openDatabase = async (): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const seedBot = async (db: CodevisorDatabaseService, slug: string, name: string) => {
  const home = await run(db.createProject({ folderPath: botPath(slug), name }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: `ws-${slug}`, projectId: home.id, name, hasCustomName: false },
      session: { id: `chat-${slug}`, projectId: home.id, harnessId: "codex", title: name }
    })
  )
  await run(
    db.createBot({
      id: `bot-${slug}`,
      name,
      symbolName: "sparkles",
      mascot: { color: "mint", hat: "none", eyewear: "none" },
      slug,
      projectId: home.id,
      sessionId: `chat-${slug}`,
      workspaceId: `ws-${slug}`,
      projects: []
    })
  )
  return { projectId: home.id, party: { kind: "bot", botId: `bot-${slug}` } as const }
}

const seedTwoBots = async () => {
  const db = await openDatabase()
  const release = await seedBot(db, "release", "Release")
  const triage = await seedBot(db, "triage", "Triage")
  return { db, release, triage }
}

const remoteAgent: ThreadParty = { kind: "agent", agentId: "agent-far", machineId: "machine-b" }

describe("threads", () => {
  it("keeps one thread per pair, whoever opens it", async () => {
    const { db, release, triage } = await seedTwoBots()

    const opened = await run(db.openThread(release.party, triage.party))
    const reopened = await run(db.openThread(triage.party, release.party))

    expect(reopened.threadId).toBe(opened.threadId)
    expect(opened.participants).toEqual([
      { kind: "bot", name: "Release", agentId: "chat-release", botId: "bot-release" },
      { kind: "bot", name: "Triage", agentId: "chat-triage", botId: "bot-triage" }
    ])
    expect(await run(db.findThread(triage.party, release.party))).toEqual(opened)
    expect(await run(db.findThread(release.party, remoteAgent))).toBeUndefined()
  })

  it("names an agent by its chat title and keeps the machine it runs on", async () => {
    const { db, release } = await seedTwoBots()
    await run(
      db.createSession({
        id: "agent-near",
        projectId: release.projectId,
        harnessId: "codex",
        title: "Fix login"
      })
    )
    const near: ThreadParty = { kind: "agent", agentId: "agent-near", machineId: "machine-a" }

    const withNear = await run(db.openThread(near, release.party))
    const withFar = await run(db.openThread(remoteAgent, release.party))

    expect(withNear.participants[0]).toEqual({
      kind: "agent",
      name: "Fix login",
      agentId: "agent-near",
      machineId: "machine-a"
    })
    expect(withFar.participants[0]).toEqual({
      kind: "agent",
      name: "",
      agentId: "agent-far",
      machineId: "machine-b"
    })
    expect(withFar.threadId).not.toBe(withNear.threadId)
  })

  it("numbers a thread's messages and pages them oldest first", async () => {
    const { db, release, triage } = await seedTwoBots()
    const { threadId } = await run(db.openThread(release.party, triage.party))

    await run(db.appendThreadMessage(threadId, release.party, "Is the build green?"))
    await run(db.appendThreadMessage(threadId, triage.party, "Yes."))
    const last = await run(db.appendThreadMessage(threadId, release.party, "Shipping."))

    expect(last).toMatchObject({
      threadId,
      sequence: 3,
      from: { kind: "bot", name: "Release", agentId: "chat-release", botId: "bot-release" },
      text: "Shipping."
    })
    const newest = await run(db.listThreadMessages(threadId, undefined, 2))
    expect(newest.messages.map((message) => message.text)).toEqual(["Yes.", "Shipping."])
    expect(newest.hasMore).toBe(true)
    const older = await run(db.listThreadMessages(threadId, 2, 2))
    expect(older).toMatchObject({ messages: [{ text: "Is the build green?" }], hasMore: false })
    expect((await run(db.getThread(threadId)))?.lastMessage).toEqual(last)
  })

  it("refuses a message from someone outside the thread", async () => {
    const { db, release, triage } = await seedTwoBots()
    const { threadId } = await run(db.openThread(release.party, triage.party))

    await expect(run(db.appendThreadMessage(threadId, remoteAgent, "Hi"))).rejects.toThrow(
      `Not in thread ${threadId}`
    )
  })

  it("lists a participant's threads newest first and leaves out the conversation with the user", async () => {
    const { db, release, triage } = await seedTwoBots()
    const withAgent = await run(db.openThread(release.party, remoteAgent))
    const withBot = await run(db.openThread(release.party, triage.party))
    await run(db.appendBotMessage("chat-release", { sender: "user", text: "Hello" }))
    await run(db.appendThreadMessage(withAgent.threadId, remoteAgent, "Done"))

    const threads = await run(db.listThreads(release.party))

    expect(threads.map((thread) => thread.threadId)).toEqual([withAgent.threadId, withBot.threadId])
    expect(threads[0]?.lastMessage?.text).toBe("Done")
    expect(await run(db.listThreads(remoteAgent))).toHaveLength(1)
  })

  it("does not read the conversation with the user as a thread", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    onTestFinished(() => run(db.close))
    await seedBot(db, "release", "Release")
    const reader = new Database(filename, { readonly: true })
    onTestFinished(() => void reader.close())
    const conversationId = String(reader.prepare("select conversation_id from bots").pluck().get())

    expect(await run(db.getThread(conversationId))).toBeUndefined()
    expect(await run(db.getThread("missing"))).toBeUndefined()
  })

  it("deletes a bot's threads with the bot", async () => {
    const { db, release, triage } = await seedTwoBots()
    const { threadId } = await run(db.openThread(release.party, triage.party))
    await run(db.appendThreadMessage(threadId, release.party, "Hi"))

    await run(db.deleteBot("bot-triage"))

    expect(await run(db.getThread(threadId))).toBeUndefined()
    expect(await run(db.listThreads(release.party))).toEqual([])
  })
})

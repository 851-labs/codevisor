import { describe, expect, it } from "vitest"

import { jsonRequest, listSubjectEvents, run, waitFor } from "../test-support.js"
import { field } from "../unknown-values.js"
import { createBot, decodeBot, setUp, type Running } from "./bot-test-support.js"

const post = (running: Running, path: string, body: unknown) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const outcome = async (response: Promise<{ readonly status: number; readonly body: unknown }>) => {
  const { status, body } = await response
  return [status, field(body, "error")]
}

const startBots = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const create = (name: string) =>
    createBot(running, { name, projectIds: ["api-project"] }).then(({ body }) => decodeBot(body))
  const release = await create("Release")
  const triage = await create("Triage")
  return { running, release, triage }
}

const addAgent = async (running: Running, id: string, extra: Record<string, unknown> = {}) => {
  await post(running, "/v1/sessions", {
    id,
    projectId: "api-project",
    harnessId: "codex",
    title: "Fix login",
    ...extra
  })
  return id
}

const deliveredTo = async (running: Running, text: string): Promise<unknown> => {
  const carries = ([, input]: ReadonlyArray<unknown>) =>
    typeof input === "string" && input.includes(text)
  await waitFor(() => running.agents.prompts.some(carries))
  return running.agents.prompts.find(carries)?.[1]
}

describe("bot threads", () => {
  it("carries a message from one bot to another and the reply back, in one thread", async () => {
    const { running, release, triage } = await startBots()

    const sent = await post(running, `/v1/bots/${triage.id}/messages`, {
      text: " Is the build green? ",
      sentByAgentId: release.sessionId
    })
    const threadId = String(field(sent.body, "threadId"))

    expect(sent.status).toBe(200)
    expect(await deliveredTo(running, "Is the build green?")).toBe(
      `<codevisor-event type="thread.message" threadId="${threadId}" from="bot" botId="${release.id}" name="Release">\nIs the build green?\n</codevisor-event>`
    )

    const reply = await post(running, `/v1/sessions/${triage.sessionId}/messages`, {
      text: "Yes, since noon.",
      threadId
    })

    expect(reply.status).toBe(200)
    expect(await deliveredTo(running, "Yes, since noon.")).toBe(
      `<codevisor-event type="thread.message" threadId="${threadId}" from="bot" botId="${triage.id}" name="Triage">\nYes, since noon.\n</codevisor-event>`
    )
    const again = await post(running, `/v1/bots/${release.id}/messages`, {
      text: "Shipping then.",
      sentByAgentId: triage.sessionId
    })
    expect(field(again.body, "threadId")).toBe(threadId)
    const read = await jsonRequest(
      running.server,
      `/v1/sessions/${release.sessionId}/messages?threadId=${threadId}&limit=2&before=4`
    )
    expect(read.body).toEqual({
      messages: [
        { from: "Triage", mine: false, text: "Yes, since noon.", sentAt: expect.any(String) },
        { from: "Triage", mine: false, text: "Shipping then.", sentAt: expect.any(String) }
      ],
      next: 2
    })
    const shown = await jsonRequest(running.server, `/v1/bots/${triage.id}/threads`)
    expect(shown.body).toMatchObject([
      {
        threadId,
        participants: [
          { kind: "bot", name: "Release", botId: release.id },
          { kind: "bot", name: "Triage", botId: triage.id }
        ],
        lastMessage: { sequence: 3, text: "Shipping then.", from: { botId: triage.id } }
      }
    ])
    const page = await jsonRequest(running.server, `/v1/threads/${threadId}/messages?limit=1`)
    expect(page.body).toMatchObject({ messages: [{ sequence: 3, threadId }], hasMore: true })
    expect(
      listSubjectEvents(running.services, threadId).map((event) => [
        event.kind,
        field(field(event.payload, "message"), "text")
      ])
    ).toEqual([
      ["thread.message", "Is the build green?"],
      ["thread.message", "Yes, since noon."],
      ["thread.message", "Shipping then."]
    ])
    const conversation = await jsonRequest(
      running.server,
      `/v1/sessions/${triage.sessionId}/conversation`
    )
    expect(field(conversation.body, "messages")).toEqual([])
  })

  it("lets an agent message a bot, read the thread, and get the bot's reply", async () => {
    const { running, release } = await startBots()
    const agentId = await addAgent(running, "agent-1")

    const sent = await post(running, `/v1/bots/${release.id}/messages`, {
      text: "Login is fixed.",
      sentByAgentId: agentId
    })
    const threadId = String(field(sent.body, "threadId"))

    expect(await deliveredTo(running, "Login is fixed.")).toBe(
      `<codevisor-event type="thread.message" threadId="${threadId}" from="agent" agentId="${agentId}" name="Fix login">\nLogin is fixed.\n</codevisor-event>`
    )
    await post(running, `/v1/sessions/${release.sessionId}/messages`, { text: "Thanks.", threadId })
    expect(await deliveredTo(running, "Thanks.")).toContain(`botId="${release.id}"`)

    const mine = await jsonRequest(
      running.server,
      `/v1/bots/${release.id}/messages?sentByAgentId=${agentId}`
    )
    expect(mine.body).toEqual({
      threadId,
      messages: [
        { from: "Fix login", mine: true, text: "Login is fixed.", sentAt: expect.any(String) },
        { from: "Release", mine: false, text: "Thanks.", sentAt: expect.any(String) }
      ]
    })
    const threads = await jsonRequest(running.server, `/v1/sessions/${release.sessionId}/threads`)
    expect(threads.body).toEqual({
      threads: [
        {
          threadId,
          with: { kind: "agent", name: "Fix login", agentId, machineId: "server-a" },
          lastMessage: { from: "Release", mine: true, text: "Thanks.", sentAt: expect.any(String) }
        }
      ]
    })
  })

  it("answers an agent that has not written to the bot with no messages", async () => {
    const { running, release } = await startBots()
    const agentId = await addAgent(running, "agent-1")

    const read = await jsonRequest(
      running.server,
      `/v1/bots/${release.id}/messages?sentByAgentId=${agentId}`
    )

    expect(read.body).toEqual({ messages: [] })
    const threads = () =>
      jsonRequest(running.server, `/v1/sessions/${release.sessionId}/threads`).then(
        (response) => response.body
      )
    expect(await threads()).toEqual({ threads: [] })

    const opened = await run(
      running.services.db.openThread(
        { kind: "bot", botId: release.id },
        { kind: "agent", agentId, machineId: "server-a" }
      )
    )

    expect(await threads()).toEqual({
      threads: [
        {
          threadId: opened.threadId,
          with: { kind: "agent", name: "Fix login", agentId, machineId: "server-a" }
        }
      ]
    })
  })

  it("refuses senders a bot should not hear from this way", async () => {
    const { running, release, triage } = await startBots()
    const owned = await addAgent(running, "owned", { createdByAgentId: release.sessionId })
    const standalone = await addAgent(running, "standalone", {
      createdByAgentId: release.sessionId
    })
    await post(running, `/v1/agents/${standalone}/detach`, {})
    const send = (botId: string, body: Record<string, unknown>) =>
      outcome(post(running, `/v1/bots/${botId}/messages`, { text: "Hi", ...body }))

    expect(await send(release.id, {})).toEqual([
      422,
      "Only a bot or an agent can message a bot this way. The user writes to a bot in the app"
    ])
    expect((await outcome(jsonRequest(running.server, `/v1/bots/${release.id}/messages`)))[0]).toBe(
      422
    )
    expect(await send(release.id, { sentByAgentId: release.sessionId })).toEqual([
      409,
      "A bot can't message itself"
    ])
    expect(await send(release.id, { sentByAgentId: owned })).toEqual([
      409,
      "Release started you and already gets your reply when your turn ends. Put what it needs in your final message"
    ])
    expect((await send(release.id, { sentByAgentId: standalone }))[0]).toBe(200)
    expect((await send(triage.id, { sentByAgentId: owned }))[0]).toBe(200)
    expect(
      await send(release.id, { sentByAgentId: "far", sentByAgentMachineId: "server-b" })
    ).toEqual([
      409,
      "Messaging a bot from another machine isn't supported yet. Use agents.message for now"
    ])
    expect(
      (await send(release.id, { sentByAgentId: owned, sentByAgentMachineId: "server-a" }))[0]
    ).toBe(409)
    expect(await send(release.id, { sentByAgentId: "missing" })).toEqual([
      404,
      "Agent not found: missing"
    ])
    expect(await send("missing", { sentByAgentId: owned })).toEqual([404, "Bot not found: missing"])
    expect(await send(triage.id, { sentByAgentId: release.sessionId, text: "  " })).toEqual([
      422,
      "A message needs text"
    ])
  })

  it("refuses a message to an archived bot and a reply to one", async () => {
    const { running, release, triage } = await startBots()
    const sent = await post(running, `/v1/bots/${triage.id}/messages`, {
      text: "Hello",
      sentByAgentId: release.sessionId
    })
    const threadId = String(field(sent.body, "threadId"))
    await jsonRequest(running.server, `/v1/bots/${release.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    expect(
      await outcome(
        post(running, `/v1/bots/${release.id}/messages`, {
          text: "Hi",
          sentByAgentId: triage.sessionId
        })
      )
    ).toEqual([409, "Release is archived"])
    expect(
      await outcome(
        post(running, `/v1/sessions/${triage.sessionId}/messages`, { text: "Hi", threadId })
      )
    ).toEqual([409, "The other side of this thread is archived or gone"])
  })

  it("keeps a thread to the bots in it", async () => {
    const { running, release, triage } = await startBots()
    const agentId = await addAgent(running, "agent-1")
    const sent = await post(running, `/v1/bots/${triage.id}/messages`, {
      text: "Hello",
      sentByAgentId: agentId
    })
    const threadId = String(field(sent.body, "threadId"))
    const reply = (sessionId: string, body: Record<string, unknown>) =>
      outcome(
        post(running, `/v1/sessions/${sessionId}/messages`, { text: "Hi", threadId, ...body })
      )

    expect(await reply(release.sessionId, {})).toEqual([404, `Thread not found: ${threadId}`])
    expect(await reply(triage.sessionId, { threadId: "missing" })).toEqual([
      404,
      "Thread not found: missing"
    ])
    expect(await reply(agentId, {})).toEqual([
      403,
      "Only a bot's own chat has messages with the user"
    ])
    expect(await reply(triage.sessionId, { attachments: [{ path: "/tmp/a.png" }] })).toEqual([
      422,
      "A message in a thread can't carry attachments yet"
    ])
    expect(await reply(triage.sessionId, { text: " " })).toEqual([422, "A message needs text"])
    expect(
      await outcome(
        jsonRequest(
          running.server,
          `/v1/sessions/${release.sessionId}/messages?threadId=${threadId}`
        )
      )
    ).toEqual([404, `Thread not found: ${threadId}`])
    expect(await outcome(jsonRequest(running.server, "/v1/threads/missing/messages"))).toEqual([
      404,
      "Thread not found: missing"
    ])
    expect(await outcome(jsonRequest(running.server, "/v1/bots/missing/threads"))).toEqual([
      404,
      "Bot not found: missing"
    ])
    expect(await outcome(jsonRequest(running.server, `/v1/sessions/${agentId}/threads`))).toEqual([
      403,
      "Only a bot has threads"
    ])
    expect(
      await outcome(
        jsonRequest(running.server, `/v1/sessions/${agentId}/messages?threadId=${threadId}`)
      )
    ).toEqual([403, "Only a bot has threads"])
  })

  it("refuses a reply to an agent that was archived", async () => {
    const { running, triage } = await startBots()
    const agentId = await addAgent(running, "agent-1")
    const sent = await post(running, `/v1/bots/${triage.id}/messages`, {
      text: "Hello",
      sentByAgentId: agentId
    })
    const threadId = String(field(sent.body, "threadId"))
    const reply = () =>
      outcome(post(running, `/v1/sessions/${triage.sessionId}/messages`, { text: "Hi", threadId }))
    await post(running, `/v1/agents/${agentId}/archive`, {})

    expect(await reply()).toEqual([409, "The other side of this thread is archived or gone"])

    await jsonRequest(running.server, `/v1/sessions/${agentId}`, { method: "DELETE" })

    expect(await reply()).toEqual([409, "The other side of this thread is archived or gone"])
  })
})

import { randomUUID } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { PromptInput } from "@codevisor/agent-runtime"
import type { AttachmentRef } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import { makeServices, run, tempDirs } from "../test-support.js"
import { steerQueuedPrompt } from "./prompt-queue.js"

const askedChat = async (presentation?: string) => {
  const { agents, services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-question-reply-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const session = await run(
    services.db.createSession({ projectId: project.id, harnessId: "codex" })
  )
  await run(services.db.appendEvent("session.updated", session.id, { turnState: "started" }))
  await run(
    services.db.appendEvent("session.output", session.id, {
      sessionUpdate: "question",
      questionId: "q",
      questions: [
        { id: "db", question: "Which database?", options: [], allowsOther: true, presentation }
      ]
    })
  )
  const fanout = await run(makeEventFanout)
  const send = async (text: string, attachments?: ReadonlyArray<AttachmentRef>) => {
    const item = await run(services.db.createPromptQueueItem(session.id, text, attachments))
    return steerQueuedPrompt(services, fanout, "server-a", session.id, item.id)
  }
  return { agents, services, session, send }
}

const recordReplies = (
  agents: Awaited<ReturnType<typeof makeServices>>["agents"],
  delivered: boolean
) => {
  const replies: Array<readonly [string, PromptInput]> = []
  vi.spyOn(agents, "replyToQuestion").mockImplementation((_sessionId, questionId, reply) =>
    Effect.sync(() => {
      replies.push([questionId, reply])
      return delivered
    })
  )
  return replies
}

const steerAll = (agents: Awaited<ReturnType<typeof makeServices>>["agents"]) => {
  const steered: Array<unknown> = []
  vi.spyOn(agents, "steer").mockImplementation((_sessionId, input) =>
    Effect.sync(() => {
      steered.push(input)
      return true
    })
  )
  return steered
}

describe("sending a message while a question waits", () => {
  it("answers the question with the message instead of steering it", async () => {
    const { agents, services, session, send } = await askedChat()
    const replies = recordReplies(agents, true)
    const steered = steerAll(agents)

    expect(await send("Use SQLite")).toBe(true)

    expect(replies).toEqual([["q", { text: "Use SQLite" }]])
    expect(steered).toEqual([])
    expect(await run(services.db.listPromptQueue(session.id))).toEqual([])
    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.items.map((item) => [item.role, item.text])).toContainEqual(["user", "Use SQLite"])
  })

  it("never answers the question with /compact, and keeps it for after the turn", async () => {
    const { agents, services, session, send } = await askedChat()
    const replies = recordReplies(agents, true)
    const steered = steerAll(agents)

    expect(await send("/compact")).toBe(false)

    expect([replies, steered]).toEqual([[], []])
    expect((await run(services.db.listPromptQueue(session.id))).map((item) => item.text)).toEqual([
      "/compact"
    ])
  })

  it("steers the message once the harness only declined the question", async () => {
    const { agents, send } = await askedChat()
    const replies = recordReplies(agents, false)
    const steered = steerAll(agents)

    expect(await send("Stop and explain first")).toBe(true)

    expect(replies).toHaveLength(1)
    expect(steered).toEqual(["Stop and explain first"])
  })

  it("hands the harness a reply's attachments", async () => {
    const { agents, services, send } = await askedChat()
    const replies = recordReplies(agents, false)
    steerAll(agents)
    const stored = await services.attachments.put(Buffer.from("fake-png"))
    const file = await run(
      services.db.createDiskFile({
        id: randomUUID(),
        name: "mock.png",
        mimeType: "image/png",
        sizeBytes: stored.sizeBytes,
        sha256: stored.sha256,
        kind: "image",
        createdAt: new Date().toISOString()
      })
    )
    const ref = {
      fileId: file.id,
      name: file.name,
      mimeType: file.mimeType,
      sizeBytes: file.sizeBytes,
      kind: "image" as const
    }

    await send("Like this", [ref])

    expect(replies[0]?.[1]).toMatchObject({
      text: "Like this",
      attachments: [{ name: "mock.png" }]
    })
  })

  it("leaves setup requests to their card", async () => {
    const { agents, send } = await askedChat("computerUsePermissions")
    const replies = recordReplies(agents, true)
    const steered = steerAll(agents)

    await send("Keep going")

    expect(replies).toEqual([])
    expect(steered).toEqual(["Keep going"])
  })
})

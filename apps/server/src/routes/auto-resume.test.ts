import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, SessionDetail, SessionSummary, TranscriptPage } from "@codevisor/api"
import type { HarnessAuthEvent } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import {
  archiveSessionViaWorkspace,
  bodyId,
  jsonRequest,
  makeServices,
  run,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"
import { fakeHarnessAuth } from "./harness-auth-test-support.js"

const accounts = ["personal", "work"]

const startServer = async () => {
  const { agents, services } = await makeServices("server-a")
  for (const id of accounts) {
    await run(
      services.db.saveHarnessAccount({
        id,
        harnessId: "codex",
        profileKind: "managed",
        profileKey: id,
        label: id,
        authState: "authenticated",
        canLogin: true,
        canLogout: true
      })
    )
  }
  const listeners: Array<(event: HarnessAuthEvent) => void> = []
  const auth = fakeHarnessAuth({
    accountContext: async (id) => ({ id, profileKind: "managed" }),
    activeAccountContext: async () => ({ id: "personal", profileKind: "managed" }),
    subscribe: (listener) => {
      listeners.push(listener)
      return () => undefined
    }
  })
  const server = await startWithApp({ ...services, auth })
  const switchAccount = async (accountId: string) => {
    await run(services.db.setActiveHarnessAccount("codex", accountId))
    for (const listener of listeners) {
      listener({
        kind: "harness.auth.updated",
        subjectId: "codex",
        payload: { activeAccountId: accountId }
      })
    }
  }
  return { agents, server, services, switchAccount }
}

type Running = Awaited<ReturnType<typeof startServer>>

const createChat = async (running: Running): Promise<string> => {
  const folder = mkdtempSync(join(tmpdir(), "codevisor-auto-resume-chat-"))
  tempDirs.push(folder)
  const project = await jsonRequest(running.server, "/v1/projects", {
    method: "POST",
    body: JSON.stringify({ folderPath: folder })
  })
  const projectId = bodyId(project)
  const session = await jsonRequest(running.server, "/v1/sessions", {
    method: "POST",
    body: JSON.stringify({ projectId, harnessId: "codex", title: "Fix login" })
  })
  return decode(SessionSummary)(session.body).id
}

const prompt = (running: Running, sessionId: string, text: string) =>
  jsonRequest(running.server, `/v1/sessions/${sessionId}/prompt`, {
    method: "POST",
    body: JSON.stringify({ text })
  })

const stopAtUsageLimit = async (
  running: Running,
  sessionId: string,
  text: string,
  resetsAt?: string
) => {
  const before = running.agents.prompts.length
  await prompt(running, sessionId, text)
  await waitFor(
    async () => running.agents.prompts.length > before && (await turnSettled(running, sessionId))
  )
  const [agentSessionId] = running.agents.prompts.at(-1) ?? [""]
  await running.agents.emit(agentSessionId, {
    kind: "session.updated",
    subjectId: agentSessionId,
    payload: {
      initiatedBy: "user",
      turnId: "limited",
      turnState: "ended",
      stopReason: "end_turn",
      stopKind: "usageLimit",
      stopDetail: "You've hit your usage limit",
      ...(resetsAt === undefined ? {} : { resetsAt })
    }
  })
}

const turnSettled = async (running: Running, sessionId: string) =>
  (await transcript(running, sessionId)).items.some(
    (item) => item.role === "assistant" && !item.isGenerating
  )

const transcript = async (running: Running, sessionId: string) =>
  decode(TranscriptPage)(
    (await jsonRequest(running.server, `/v1/sessions/${sessionId}/transcript`)).body
  )

const detail = async (running: Running, sessionId: string) =>
  decode(SessionDetail)((await jsonRequest(running.server, `/v1/sessions/${sessionId}`)).body)

const resumePrompts = (running: Running) =>
  running.agents.prompts.flatMap(([, input]) =>
    typeof input === "string" && input.includes('type="session.usage_limit_reset"') ? [input] : []
  )

describe("auto-resume for chats stopped at a usage limit", () => {
  it("shows the pending resume on the chat until the user declines it", async () => {
    const running = await startServer()
    const chat = await createChat(running)

    await stopAtUsageLimit(running, chat, "Fix the login form", "2099-01-01T00:00:00.000Z")
    await waitFor(async () => (await transcript(running, chat)).autoResume !== undefined)

    expect((await transcript(running, chat)).autoResume).toEqual({
      resumesAt: "2099-01-01T00:00:00.000Z"
    })
    const declined = await jsonRequest(running.server, `/v1/sessions/${chat}/auto-resume`, {
      method: "DELETE"
    })
    expect(declined.status).toBe(204)
    expect((await transcript(running, chat)).autoResume).toBeUndefined()
    expect((await detail(running, chat)).autoResume).toBeUndefined()
  })

  it("resumes on the new account with a hidden continue prompt when the user switches accounts", async () => {
    const running = await startServer()
    const chat = await createChat(running)
    await stopAtUsageLimit(running, chat, "Refactor the login form")
    await waitFor(async () => (await detail(running, chat)).autoResume !== undefined)
    expect((await detail(running, chat)).autoResume).toEqual({})

    await running.switchAccount("work")
    await waitFor(() => resumePrompts(running).length === 1)

    expect(resumePrompts(running)[0]).toContain(
      "The user's last message, for reference:\nRefactor the login form"
    )
    expect((await run(running.services.db.getSessionSummary(chat))).harnessAccountId).toBe("work")
    await waitFor(async () => (await run(running.services.db.getAutoResume(chat))) === undefined)
    const hidden = (await transcript(running, chat)).items.filter((item) => item.origin === "event")
    expect(hidden).toHaveLength(1)
  })

  it("drops the resume instead of waking a chat whose workspace was archived meanwhile", async () => {
    const running = await startServer()
    const chat = await createChat(running)
    await stopAtUsageLimit(running, chat, "Fix the login form", "2099-01-01T00:00:00.000Z")
    await waitFor(async () => (await detail(running, chat)).autoResume !== undefined)
    const { projectId } = await run(running.services.db.getSessionSummary(chat))
    await archiveSessionViaWorkspace(running.services, projectId, chat)

    await running.switchAccount("work")
    await waitFor(async () => (await run(running.services.db.getAutoResume(chat))) === undefined)

    expect(resumePrompts(running)).toEqual([])
  })
})

import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"

type Started = Awaited<ReturnType<typeof start>>

describe("a chat's harness account", () => {
  it("stays where the server put it when an app saves or opens the chat with an older account", async () => {
    const { server, services } = await start()
    const chat = await chatOn(services, "work")
    const staleCopy = {
      title: "Saved by the app",
      harnessId: "claude-code",
      harnessAccountId: "personal"
    }

    const saved = await jsonRequest(server, `/v1/sessions/${chat.id}`, {
      body: JSON.stringify(staleCopy),
      method: "PATCH"
    })
    const opened = await jsonRequest(server, `/v1/sessions/${chat.id}/open`, {
      body: JSON.stringify({
        session: { ...staleCopy, id: chat.id, projectId: chat.projectId },
        update: staleCopy
      }),
      method: "POST"
    })

    expect(saved).toMatchObject({ status: 200, body: { harnessAccountId: "work" } })
    expect(opened).toMatchObject({ status: 200, body: { session: { harnessAccountId: "work" } } })
  })

  it("is dropped when the chat moves to another harness, so the next start picks that harness's account", async () => {
    const { server, services } = await start()
    const chat = await chatOn(services, "work")

    await jsonRequest(server, `/v1/sessions/${chat.id}`, {
      body: JSON.stringify({ harnessId: "codex" }),
      method: "PATCH"
    })

    const moved = await run(services.db.getSessionSummary(chat.id))
    expect(moved.harnessId).toBe("codex")
    expect(moved.harnessAccountId).toBeUndefined()
  })
})

const chatOn = async (services: Started["services"], accountId: string) => {
  const folder = mkdtempSync(join(tmpdir(), "codevisor-account-owner-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  for (const id of ["personal", accountId]) await saveAccount(services, id)

  return run(
    services.db.createSession({
      projectId: project.id,
      harnessId: "claude-code",
      harnessAccountId: accountId,
      agentSessionId: ""
    })
  )
}

const saveAccount = (services: Started["services"], id: string) =>
  run(
    services.db.saveHarnessAccount({
      id,
      harnessId: "claude-code",
      profileKind: "managed",
      profileKey: id,
      label: id,
      authState: "authenticated",
      canLogin: true,
      canLogout: true
    })
  )

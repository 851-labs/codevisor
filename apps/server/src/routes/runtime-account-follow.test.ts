import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, SessionSummary } from "@codevisor/api"
import type { HarnessAuthEvent } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import {
  bodyId,
  jsonRequest,
  makeServices,
  run,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"
import { fakeHarnessAuth } from "./harness-auth-test-support.js"

const harnesses = ["codex", "claude-code"]

const startServer = async () => {
  const { agents, services } = await makeServices("server-a")
  for (const harnessId of harnesses) {
    for (const id of ["personal", "work"]) await saveAccount(services, harnessId, id)
  }
  const listeners: Array<(event: HarnessAuthEvent) => void> = []
  const auth = fakeHarnessAuth({
    accountContext: async (id) => ({ id, profileKind: "managed" }),
    activeAccountContext: async (harnessId) => ({
      id: accountId(harnessId, "personal"),
      profileKind: "managed"
    }),
    subscribe: (listener) => {
      listeners.push(listener)
      return () => undefined
    }
  })
  const server = await startWithApp({ ...services, auth })
  const switchAccount = async (harnessId: string) => {
    const [from, to] = [accountId(harnessId, "personal"), accountId(harnessId, "work")]
    await run(services.db.setActiveHarnessAccount(harnessId, to))
    await run(services.db.rebindHarnessAccountSessions(from, to))
    for (const listener of listeners) {
      listener({ kind: "harness.auth.updated", subjectId: harnessId, payload: {} })
    }
  }
  return { agents, server, services, switchAccount }
}

type Running = Awaited<ReturnType<typeof startServer>>

const saveAccount = (
  services: Running["services"],
  harnessId: string,
  name: string
): Promise<unknown> =>
  run(
    services.db.saveHarnessAccount({
      id: accountId(harnessId, name),
      harnessId,
      profileKind: "managed",
      profileKey: accountId(harnessId, name),
      label: name,
      authState: "authenticated",
      canLogin: true,
      canLogout: true
    })
  )

const accountId = (harnessId: string, name: string): string => `${harnessId}-${name}`

const createChat = async (running: Running, harnessId: string) => {
  const folder = mkdtempSync(join(tmpdir(), "codevisor-account-follow-"))
  tempDirs.push(folder)
  const project = await jsonRequest(running.server, "/v1/projects", {
    method: "POST",
    body: JSON.stringify({ folderPath: folder })
  })
  const created = await jsonRequest(running.server, "/v1/sessions", {
    method: "POST",
    body: JSON.stringify({ projectId: bodyId(project), harnessId, title: "Fix login" })
  })
  const chat = decode(SessionSummary)(created.body)
  return { id: chat.id, agent: chat.agentSessionId ?? "" }
}

const runningAccount = (running: Running, agentSessionId: string): string | undefined =>
  running.agents.loadedAgentSessions().find((loaded) => loaded.sessionId === agentSessionId)
    ?.harnessAccountId

const emitUpdate = (running: Running, agentSessionId: string, payload: Record<string, unknown>) =>
  running.agents.emit(agentSessionId, {
    kind: "session.updated",
    subjectId: agentSessionId,
    payload
  })

const backgroundTask = {
  id: "task-1",
  description: "Wait for the machine load to drop",
  status: "running",
  taskType: "local_bash"
}

describe("chat agents follow the account their chat is moved to", () => {
  it("restarts an idle chat's agent on the new account right away", async () => {
    const running = await startServer()
    const chat = await createChat(running, "codex")
    expect(runningAccount(running, chat.agent)).toBe("codex-personal")

    await running.switchAccount("codex")
    await waitFor(() => runningAccount(running, chat.agent) === "codex-work")

    expect(running.agents.loads).toContainEqual(["codex", chat.agent, expect.any(String)])
  })

  it("keeps a chat with a running background task on its agent until its wake-up turn ends", async () => {
    const running = await startServer()
    const busy = await createChat(running, "codex")
    const sentinel = await createChat(running, "claude-code")
    await emitUpdate(running, busy.agent, { backgroundTasks: [backgroundTask] })

    await running.switchAccount("codex")
    await running.switchAccount("claude-code")
    await waitFor(() => runningAccount(running, sentinel.agent) === "claude-code-work")
    expect(runningAccount(running, busy.agent)).toBe("codex-personal")

    await emitUpdate(running, busy.agent, { backgroundTasks: [] })
    await emitUpdate(running, busy.agent, {
      initiatedBy: "agent",
      turnId: "wake",
      turnState: "started"
    })
    await emitUpdate(running, busy.agent, {
      initiatedBy: "agent",
      turnId: "wake",
      turnState: "ended",
      stopReason: "end_turn"
    })

    await waitFor(() => runningAccount(running, busy.agent) === "codex-work")
  })
})

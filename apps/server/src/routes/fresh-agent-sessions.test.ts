import { decode } from "@codevisor/api"
import { expect, it } from "vitest"

import { jsonRequest, listSubjectEvents, run, waitFor } from "../test-support.js"
import { endedTurns, setUp } from "./bot-test-support.js"
import { CreatedSession } from "./session-test-support.js"

const startChat = async () => {
  const running = await setUp()
  await running.addProject("fresh-project", "fresh")
  const created = decode(CreatedSession)(
    (
      await jsonRequest(running.server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "fresh-project", harnessId: "codex" }),
        method: "POST"
      })
    ).body
  )
  const prompt = async (text: string) => {
    const ended = endedTurns(running, created.id)
    await jsonRequest(running.server, `/v1/sessions/${created.id}/prompt`, {
      body: JSON.stringify({ text }),
      method: "POST"
    })
    await waitFor(() => endedTurns(running, created.id) > ended)
  }
  const restartRuntime = () => running.agents.sinks.clear()
  const agentSessionId = async () =>
    (await run(running.services.db.getSessionSummary(created.id))).agentSessionId
  return { agentSessionId, created, prompt, restartRuntime, running }
}

it("starts a new chat's agent afresh after a runtime restart, without resuming what was never saved", async () => {
  const { agentSessionId, created, prompt, restartRuntime, running } = await startChat()

  restartRuntime()
  await prompt("hello")

  expect(running.agents.creations).toHaveLength(2)
  expect(running.agents.prompts).toEqual([[await agentSessionId(), "hello"]])
  expect(listSubjectEvents(running.services, created.id).map((event) => event.kind)).not.toContain(
    "session.error"
  )
})

it("keeps using a new chat's warm agent for its first message", async () => {
  const { created, prompt, running } = await startChat()

  await prompt("hello")

  expect(running.agents.prompts).toEqual([[created.agentSessionId, "hello"]])
  expect(running.agents.creations).toHaveLength(1)
})

it("resumes a chat's agent after a runtime restart once it has had a turn", async () => {
  const { created, prompt, restartRuntime, running } = await startChat()
  await prompt("hello")

  restartRuntime()
  await prompt("again")

  expect(running.agents.creations).toHaveLength(1)
  expect(running.agents.loads.at(-1)?.[1]).toBe(created.agentSessionId)
  expect(running.agents.prompts.at(-1)).toEqual([created.agentSessionId, "again"])
})

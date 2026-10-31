import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { AgentRuntimeError } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { expect, it, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import { idleRouteState, makeServices, run, tempDirs } from "../test-support.js"
import {
  CONVERSATION_RECAP_MAX_CHARS,
  rememberConversationRecap,
  withConversationRecap
} from "./conversation-recap.js"
import { drainPromptQueue } from "./prompt-queue.js"

const missingConversation = new AgentRuntimeError({
  operation: "loadSession",
  message: "Claude Code couldn't find this chat's saved conversation.",
  conversationMissing: true
})

const setUp = async () => {
  const { agents, services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-conversation-recap-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const session = await run(
    services.db.createSession({
      projectId: project.id,
      harnessId: "claude-code",
      agentSessionId: "lost"
    })
  )
  const fanout = await run(makeEventFanout)
  const state = idleRouteState()
  const send = async (text: string) => {
    await run(services.db.createPromptQueueItem(session.id, text))
    await drainPromptQueue(services, fanout, state, "server-a", session.id)
  }
  const loseConversation = () => {
    const load = agents.loadAgentSession
    return vi
      .spyOn(agents, "loadAgentSession")
      .mockImplementation((harnessId, agentSessionId, ...rest) =>
        agentSessionId === "lost"
          ? Effect.fail(missingConversation)
          : load(harnessId, agentSessionId, ...rest)
      )
  }
  return { agents, loseConversation, send, services, session }
}

it("starts a chat whose conversation is lost afresh, with the earlier turns as context", async () => {
  const { agents, loseConversation, send, services, session } = await setUp()
  await send("Remember the codeword PINEAPPLE.")
  const lost = loseConversation()

  try {
    await send("What was the codeword?")
    await send("Thanks")
  } finally {
    lost.mockRestore()
  }

  const fresh = (await run(services.db.getSessionSummary(session.id))).agentSessionId
  expect(fresh).not.toBe("lost")
  expect(agents.creations).toHaveLength(1)
  const [recapped, next] = agents.prompts.slice(1).map(([, input]) => input)
  expect(agents.prompts.slice(1).map(([agentSessionId]) => agentSessionId)).toEqual([fresh, fresh])
  expect(recapped).toBe(
    [
      "<codevisor-earlier-conversation>",
      "The agent couldn't resume this chat's earlier session, so this is a new session. " +
        "Here is the conversation so far, for context:",
      "",
      "User: Remember the codeword PINEAPPLE.\n",
      "Assistant: Echo: Remember the codeword PINEAPPLE.\n",
      "</codevisor-earlier-conversation>",
      "",
      "What was the codeword?"
    ].join("\n")
  )
  expect(next).toBe("Thanks")
})

it("starts an empty chat whose conversation was never saved afresh, with nothing to recap", async () => {
  const { agents, loseConversation, send, services, session } = await setUp()
  const lost = loseConversation()

  try {
    await send("Hello")
  } finally {
    lost.mockRestore()
  }

  const fresh = (await run(services.db.getSessionSummary(session.id))).agentSessionId
  expect(agents.prompts).toEqual([[fresh, "Hello"]])
})

it("recaps only the most recent turns that fit, ending with the agent's last reply", async () => {
  const { services, session } = await setUp()
  const said = async (role: "user" | "assistant", text: string) =>
    run(services.db.appendConversationItem(session.id, role, undefined, text, false))
  await said("user", `Old request ${"x".repeat(CONVERSATION_RECAP_MAX_CHARS)}`)
  await said("assistant", "Old answer")
  await said("user", "Recent question")
  await said("assistant", "Recent answer")

  await rememberConversationRecap(services, session.id)
  const recapped = withConversationRecap(services, session.id, "Next")

  expect(recapped).toContain("User: Recent question\n")
  expect(recapped).toContain("Assistant: Recent answer\n")
  expect(recapped).toContain("Assistant: Old answer\n")
  expect(recapped).not.toContain("Old request")
  expect(recapped.endsWith("</codevisor-earlier-conversation>\n\nNext")).toBe(true)
  expect(withConversationRecap(services, session.id, "Later")).toBe("Later")
})

it.each([
  { length: 20, opening: true },
  { length: 600, opening: false }
])(
  "pages back through a long chat until the recap is full (messages of $length characters)",
  async ({ length, opening }) => {
    const { services, session } = await setUp()
    for (let index = 0; index < 60; index += 1) {
      const role = index % 2 === 0 ? "user" : "assistant"
      const text = `Message ${index} `.padEnd(length, ".")
      await run(services.db.appendConversationItem(session.id, role, undefined, text, false))
    }

    await rememberConversationRecap(services, session.id)
    const recapped = withConversationRecap(services, session.id, "Next")

    expect(recapped).toContain("Assistant: Message 59 ")
    expect(recapped.includes("User: Message 0 ")).toBe(opening)
  }
)

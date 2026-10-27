import { describe, expect, it } from "vitest"

import { payloadOf, run, setup } from "./test-support.js"

const failTurn = async (error: Record<string, unknown>) => {
  const { client, created, events } = await setup()
  const turnRequested = client.nextRequest("turn/start")
  const prompt = run(created!.handle.prompt("try this"))
  await turnRequested
  client.emit("turn/started", {
    threadId: "thread-new",
    turn: { id: "turn-1", status: "inProgress" }
  })
  client.emit("turn/completed", {
    threadId: "thread-new",
    turn: { id: "turn-1", status: "failed", error }
  })
  await prompt
  return payloadOf(events.at(-1))
}

const orgBlocked = "Your organization has disabled Codex access for this workspace"

describe("Codex turn failures", () => {
  it.each([
    [
      "an HTTP 403",
      {
        message: "unexpected status 403 Forbidden: Request blocked",
        codexErrorInfo: { responseStreamConnectionFailed: { httpStatusCode: 403 } }
      },
      { stopDetail: "unexpected status 403 Forbidden: Request blocked", stopKind: "forbidden" }
    ],
    [
      "an access block without a status",
      { message: orgBlocked, codexErrorInfo: "other" },
      { stopDetail: orgBlocked, stopKind: "forbidden" }
    ],
    [
      "a server error",
      {
        message: "unexpected status 500 Internal Server Error",
        codexErrorInfo: "internalServerError"
      },
      { stopDetail: "unexpected status 500 Internal Server Error", stopKind: "harnessFailed" }
    ],
    [
      "an unauthorized request",
      { message: "unexpected status 401 Unauthorized", codexErrorInfo: "unauthorized" },
      { stopDetail: "Codex isn't signed in. Sign in to continue.", stopKind: "authRequired" }
    ],
    [
      "a usage limit",
      { message: "You've hit your usage limit.", codexErrorInfo: "usageLimitExceeded" },
      { stopDetail: "You've hit your usage limit.", stopKind: "usageLimit" }
    ],
    [
      "an API key out of quota",
      {
        message: "Quota exceeded. Check your plan and billing details.",
        codexErrorInfo: "other"
      },
      {
        stopDetail: "Quota exceeded. Check your plan and billing details.",
        stopKind: "usageLimit"
      }
    ]
  ])("ends the turn with the failure kind for %s", async (_, error, stop) => {
    expect(await failTurn(error)).toMatchObject({ ...stop, turnState: "ended" })
  })
})

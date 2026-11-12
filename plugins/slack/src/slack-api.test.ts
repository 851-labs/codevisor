import { describe, expect, it } from "vitest"

import { type Fetch, slackApi } from "./slack-api.js"

const replying =
  (response: () => Response): Fetch =>
  async () =>
    response()

const failure = (fetcher: Fetch) =>
  slackApi(fetcher, "xoxp-t")
    .call("conversations.history", { channel: "C1" })
    .then(
      () => "resolved",
      (error: unknown) => (error instanceof Error ? error.message : String(error))
    )

describe("Slack Web API errors", () => {
  it("says how long Slack wants us to wait when it rate limits", async () => {
    const limited = replying(
      () => new Response(null, { status: 429, headers: { "retry-after": "30" } })
    )

    expect(await failure(limited)).toBe(
      "Slack is rate limiting these requests. Try again in 30 seconds."
    )
  })

  it("explains known errors and names unknown ones", async () => {
    const known = replying(() => Response.json({ ok: false, error: "channel_not_found" }))
    const unknown = replying(() => Response.json({ ok: false, error: "fatal_error" }))

    expect([await failure(known), await failure(unknown)]).toEqual([
      "Slack couldn't find that conversation, or you aren't in it.",
      "Slack returned fatal_error."
    ])
  })

  it("reports a reply that isn't Slack JSON", async () => {
    const html = replying(() => new Response("<html>", { status: 502 }))

    expect(await failure(html)).toBe(
      "Slack sent an unreadable reply to conversations.history (HTTP 502)."
    )
  })

  it("sends objects as JSON form values and leaves out missing ones", async () => {
    const bodies: Array<string> = []
    const recording: Fetch = async (_url, init) => {
      bodies.push(typeof init.body === "string" ? init.body : "")
      return Response.json({ ok: true })
    }

    await slackApi(recording, "xoxp-t").call("files.completeUploadExternal", {
      files: [{ id: "F1" }],
      thread_ts: undefined,
      channel_id: "C1"
    })

    expect(Object.fromEntries(new URLSearchParams(bodies[0]))).toEqual({
      files: '[{"id":"F1"}]',
      channel_id: "C1"
    })
  })

  it("fails file transfers Slack refuses", async () => {
    const refused = replying(() => new Response("no", { status: 403 }))
    const api = slackApi(refused, "xoxp-t")

    await expect(api.fetchFile("https://files.slack.com/x")).rejects.toThrow(
      "Slack didn't send the file (HTTP 403)."
    )
    await expect(api.sendFile("https://files.slack.com/up", new Uint8Array(1))).rejects.toThrow(
      "Slack didn't take the file (HTTP 403)."
    )
  })
})

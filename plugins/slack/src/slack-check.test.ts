import { anyResult } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import { connectSlack, signingSecret, slackAccountMeta, userToken } from "./slack-test-support.js"

const check = async (fields: Record<string, unknown>) => {
  const connected = await connectSlack()
  const result = connected.client.request(
    { method: "codevisor/account/check", params: { _meta: slackAccountMeta(fields) } },
    anyResult
  )
  return { connected, result }
}

describe("account check", () => {
  it("names the account after the workspace and the user", async () => {
    const { result } = await check({ userToken, signingSecret })

    await expect(result).resolves.toEqual({ identity: "@dana · acme.slack.com", label: "Acme" })
  })

  it("explains which token was pasted when it isn't the user token", async () => {
    const bot = await check({ userToken: "xoxb-123", signingSecret })
    const other = await check({ userToken: "hello", signingSecret })

    await expect(bot.result).rejects.toThrow("That's the Bot User OAuth Token")
    await expect(other.result).rejects.toThrow("starts with xoxp-")
  })

  it("rejects a signing secret that isn't 32 hex characters", async () => {
    const { result } = await check({ userToken, signingSecret: "not-a-secret" })

    await expect(result).rejects.toThrow("doesn't look like a Signing Secret")
  })

  it("lists the scopes the installed app is missing", async () => {
    const connected = await connectSlack()
    connected.slack.scopes.splice(0, connected.slack.scopes.length, "chat:write", "search:read")

    const result = connected.client.request(
      { method: "codevisor/account/check", params: { _meta: slackAccountMeta() } },
      anyResult
    )

    await expect(result).rejects.toThrow(
      /missing channels:history, channels:read, .*users:read\.email\./
    )
  })

  it("passes on Slack's rejection of the token", async () => {
    const { result } = await check({ userToken: "xoxp-revoked", signingSecret })

    await expect(result).rejects.toThrow("Slack didn't accept that token.")
  })
})

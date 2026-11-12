import { describe, expect, it } from "vitest"

import { type AccountCheckConnections, checkPluginAccount } from "./plugin-account-check.js"

const serverId = "slack-1"
const account = { id: "acct-1", fields: { token: "t" } }

const pluginReplying = (reply: () => Promise<Record<string, unknown>>) => {
  const sent: Array<unknown> = []
  const connect: AccountCheckConnections = async () => ({
    request: async (method, params, options) => {
      sent.push({ method, params, options })
      return reply()
    }
  })
  return { connect, sent }
}

const offline: AccountCheckConnections = async () => {
  throw new Error("not connected")
}

const protocolError = (code: number, message: string) => Object.assign(new Error(message), { code })

describe("plugin account checks", () => {
  it("sends the unsaved account to the plugin and keeps the name it returns", async () => {
    const { connect, sent } = pluginReplying(async () => ({
      identity: "@dana · acme",
      label: "Acme",
      extra: 1
    }))

    expect(await checkPluginAccount(connect, serverId, account)).toEqual({
      identity: "@dana · acme",
      label: "Acme"
    })
    expect(sent).toEqual([
      {
        method: "codevisor/account/check",
        params: {},
        options: { meta: { "dev.codevisor/account": account }, timeoutMs: 20_000 }
      }
    ])
  })

  it("turns the plugin's rejection into a 400 with its reason", async () => {
    const { connect } = pluginReplying(async () => {
      throw protocolError(-32602, "That's the bot token")
    })

    await expect(checkPluginAccount(connect, serverId, account)).rejects.toMatchObject({
      status: 400,
      message: "That's the bot token"
    })
  })

  it("saves unchecked when the plugin has no check or can't be reached", async () => {
    const unsupported = pluginReplying(async () => {
      throw protocolError(-32601, "Method not found")
    })

    expect(await checkPluginAccount(unsupported.connect, serverId, account)).toBeUndefined()
    expect(await checkPluginAccount(offline, serverId, account)).toBeUndefined()
  })
})

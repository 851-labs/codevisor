import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"

import { inboxDevice, sealedInboxItem } from "../infra/cloud-inbox-test-support.js"
import { makeCloudInbox } from "../infra/cloud-inbox.js"
import { fakeOAuthProvider, routeGoogleTo } from "./accounts/plugin-oauth-test-support.js"
import { savePluginRow } from "./events/plugin-events-test-support.js"
import { makePluginCatalog } from "./plugin-catalog.js"
import { makePluginPlatform } from "./plugin-platform.js"
import {
  cloudRedirect,
  fakeCloud,
  localBaseUrl,
  pluginServices,
  type CloudReply
} from "./plugin-test-support.js"

const relayedPlatform = async (reply?: CloudReply) => {
  const { cloud, requests } = fakeCloud(reply)
  const inbox = makeCloudInbox()
  const started = await pluginServices({ cloud, inbox })
  const gmail = await savePluginRow(started.services.db, "Gmail", {
    catalogId: "dev.codevisor/gmail",
    enabled: false
  })
  const finishedMcp: Array<ReadonlyArray<string>> = []
  started.platform.attachMcp({
    ...started.mcp,
    finishOAuth: async (state, code) => {
      finishedMcp.push([state, code])
      return gmail
    }
  })
  const startGmail = () =>
    started.platform.accounts.startOAuth(gmail.id, {
      values: { clientId: "client-1", clientSecret: "client-secret" }
    })
  const relay = (itemId: string, callback: Record<string, string>) =>
    inbox.receive(
      inboxDevice.secretKey,
      sealedInboxItem(itemId, "oauth", { flowId: "flow", ...callback })
    )
  return { ...started, gmail, requests, finishedMcp, startGmail, relay }
}

describe("plugin platform", () => {
  it("signs in through a cloud-registered redirect and finishes from the relayed callback", async () => {
    const platform = await relayedPlatform()
    const provider = await fakeOAuthProvider()
    routeGoogleTo(provider.url)

    const started = await platform.startGmail()
    const grant = provider.authorize(started.authorizationUrl)
    await platform.relay("callback-1", { state: grant.state, code: grant.code })

    expect(new URL(started.authorizationUrl).searchParams.get("redirect_uri")).toBe(cloudRedirect)
    expect(grant.state).toMatch(new RegExp(`^${started.flowId}\\.device-1\\.`))
    expect(platform.requests).toEqual([
      { method: "POST", path: "/api/machine/oauth-flows", body: { flowId: started.flowId } }
    ])
    expect(await platform.platform.accounts.list(platform.gmail.id)).toEqual([
      expect.objectContaining({ identity: "dana@example.com", method: "oauth2" })
    ])
    expect(platform.finishedMcp).toEqual([])
  })

  it("hands relayed callbacks it didn't start to MCP sign-in", async () => {
    const platform = await relayedPlatform()
    const started = await platform.startGmail()
    const state = new URL(started.authorizationUrl).searchParams.get("state")!

    await platform.relay("cancelled", { state, error: "access_denied" })
    await platform.relay("mcp-denied", { state: "mcp-flow.device-1.nonce", error: "access_denied" })
    await platform.relay("mcp", { state: "mcp-flow.device-1.nonce", code: "mcp-code" })

    expect(platform.platform.accounts.ownsOAuthState(state)).toBe(false)
    expect(platform.finishedMcp).toEqual([["mcp-flow.device-1.nonce", "mcp-code"]])
  })

  it("refuses to sign in when the cloud returns no redirect", async () => {
    const replies: ReadonlyArray<unknown> = [{ ok: true }, null]
    let asked = 0
    const platform = await relayedPlatform(() => replies[asked++])

    await expect(platform.startGmail()).rejects.toThrow("The cloud didn't return an OAuth redirect")
    await expect(platform.platform.mcpOAuthRedirect("server-1")).rejects.toThrow(
      "The cloud didn't return an OAuth redirect"
    )
  })

  it("registers MCP sign-in redirects with the cloud only while linked", async () => {
    const linked = await relayedPlatform()
    const local = await pluginServices()

    const relayed = await linked.platform.mcpOAuthRedirect("server-1")
    const unlinked = await local.platform.mcpOAuthRedirect("server-1")

    expect(relayed).toEqual({
      redirectUrl: cloudRedirect,
      state: expect.stringMatching(/^[\w-]+\.device-1\.[\w-]+$/)
    })
    expect(unlinked).toBeUndefined()
  })

  it("asks the cloud for a managed OAuth client and its token exchanges", async () => {
    const { cloud, requests } = fakeCloud((method) =>
      method === "GET" ? { clientId: "github-client" } : { access_token: "gho_1" }
    )
    const linked = await pluginServices({ cloud })

    const clientId = await linked.platform.managedOAuth.clientId("github")
    const tokens = await linked.platform.managedOAuth.exchange(
      "github",
      "https://github.com/login/oauth/access_token",
      "grant_type=authorization_code"
    )

    expect([clientId, tokens]).toEqual(["github-client", { access_token: "gho_1" }])
    expect(requests).toEqual([
      {
        method: "GET",
        path: "/api/machine/oauth-clients/github",
        body: undefined
      },
      {
        method: "POST",
        path: "/api/machine/oauth-clients/github/token",
        body: {
          tokenUrl: "https://github.com/login/oauth/access_token",
          form: "grant_type=authorization_code"
        }
      }
    ])
  })

  it("needs a linked cloud and a client id back for managed OAuth clients", async () => {
    const local = await pluginServices()
    const empty = await relayedPlatform(() => ({}))

    await expect(local.platform.managedOAuth.clientId("github")).rejects.toThrow(
      "Sign in to Codevisor to connect this plugin"
    )
    await expect(empty.platform.managedOAuth.clientId("github")).rejects.toThrow(
      "The cloud didn't return an OAuth client"
    )
  })

  it("tells listeners about saved accounts until they unsubscribe", async () => {
    const started = await pluginServices()
    const grafana = await savePluginRow(started.services.db, "Grafana", {
      catalogId: "dev.codevisor/grafana",
      enabled: false
    })
    const heard: Array<ReadonlyArray<SyncEntryRecord>> = []
    const stop = started.platform.onAccountsChanged((entries) => heard.push(entries))
    const values = { url: "https://grafana.example.com", token: "glsa_secret" }

    const saved = await started.platform.accounts.saveFields(grafana.id, { values })
    stop()
    await started.platform.accounts.saveFields(grafana.id, { values }, saved.id)

    expect(heard).toEqual([[expect.objectContaining({ key: saved.id, deleted: false })]])
  })

  it("reports no accounts for plugins it can't look up", async () => {
    const attached = await pluginServices()
    const detached = makePluginPlatform({
      db: attached.services.db,
      serverId: "server-a",
      vault: attached.vault,
      catalog: makePluginCatalog({ dev: false, execPath: process.execPath }),
      cloud: undefined,
      inbox: undefined,
      localBaseUrl
    })

    expect(await detached.accountSource.list("server-1")).toEqual([])
    expect(await detached.accountSource.meta("server-1")).toBeUndefined()
    await expect(detached.accounts.list("server-1")).rejects.toMatchObject({ status: 501 })
    expect(await attached.platform.accountSource.list("missing")).toEqual([])
    expect(await attached.platform.accountSource.meta("missing")).toBeUndefined()
    expect(detached.deviceId()).toBeUndefined()
  })
})

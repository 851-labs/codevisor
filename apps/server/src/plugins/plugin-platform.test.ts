import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"

import { fakeOAuthProvider, routeGoogleTo } from "./accounts/plugin-oauth-test-support.js"
import { savePluginRow } from "./events/plugin-events-test-support.js"
import { makePluginCatalog } from "./plugin-catalog.js"
import { makePluginPlatform } from "./plugin-platform.js"
import { fakeCloud, localBaseUrl, pluginServices, type CloudReply } from "./plugin-test-support.js"

const linkedPlatform = async (reply?: CloudReply) => {
  const { cloud, requests } = fakeCloud(reply)
  const started = await pluginServices({ cloud })
  const gmail = await savePluginRow(started.services.db, "Gmail", {
    catalogId: "dev.codevisor/gmail",
    enabled: false
  })
  const startGmail = () =>
    started.platform.accounts.startOAuth(gmail.id, {
      values: { clientId: "client-1", clientSecret: "client-secret" }
    })
  return { ...started, gmail, requests, startGmail }
}

describe("plugin platform", () => {
  it("signs accounts in through the machine's own callback even when linked to the cloud", async () => {
    const platform = await linkedPlatform()
    const provider = await fakeOAuthProvider()
    routeGoogleTo(provider.url)

    const started = await platform.startGmail()
    const grant = provider.authorize(started.authorizationUrl)
    await platform.platform.accounts.completeOAuth(grant.state, grant.code)

    expect(new URL(started.authorizationUrl).searchParams.get("redirect_uri")).toBe(
      new URL("/v1/plugins/oauth/callback", localBaseUrl).toString()
    )
    expect(platform.requests).toEqual([])
    expect(await platform.platform.accounts.list(platform.gmail.id)).toEqual([
      expect.objectContaining({ identity: "dana@example.com", method: "oauth2" })
    ])
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
    const empty = await linkedPlatform(() => ({}))

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

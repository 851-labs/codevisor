import {
  decode,
  PluginAccount,
  PluginAccountOAuthStart,
  PluginAccountsResponse
} from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run } from "../../test-support.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import {
  localBaseUrl,
  post,
  startPluginApp,
  startWithoutPlugins,
  type PluginServicesOptions
} from "../plugin-test-support.js"
import { PLUGIN_ACCOUNTS_NAMESPACE, makePluginAccountStore } from "./plugin-account-store.js"
import { fakeOAuthProvider, routeGoogleTo } from "./plugin-oauth-test-support.js"

const grafanaApp = async (options: PluginServicesOptions = {}) => {
  const running = await startPluginApp(options)
  const grafana = await savePluginRow(running.services.db, "Grafana", {
    catalogId: "dev.codevisor/grafana",
    enabled: false
  })
  const accountsPath = `/v1/plugins/${grafana.id}/accounts`
  const credentialOf = async (accountId: string) =>
    (await makePluginAccountStore(running.services.db, "server-a").get(accountId))!.credential!
  return { ...running, grafana, accountsPath, credentialOf }
}

const grafanaValues = { url: "https://grafana.example.com/", token: "glsa_secret" }

const send = (
  running: Awaited<ReturnType<typeof grafanaApp>>,
  method: string,
  path: string,
  body?: unknown
) =>
  jsonRequest(running.server, path, {
    method,
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })

describe("plugin account routes", () => {
  it("saves a Grafana account and never returns or syncs its secrets", async () => {
    const running = await grafanaApp()

    const saved = await post(running, running.accountsPath, { values: grafanaValues })
    const listed = await jsonRequest(running.server, running.accountsPath)

    const account = decode(PluginAccount)(saved.body)
    expect(account).toEqual({
      id: expect.any(String),
      plugin: "dev.codevisor/grafana",
      label: "grafana.example.com",
      method: "fields",
      values: { url: "https://grafana.example.com" },
      secretsSet: ["token", "webhookSecret"],
      status: "ok",
      createdAt: expect.any(String)
    })
    expect(decode(PluginAccountsResponse)(listed.body).accounts).toEqual([account])
    const synced = await run(running.services.db.getSyncEntries(PLUGIN_ACCOUNTS_NAMESPACE))
    expect(JSON.stringify([saved.body, listed.body, synced])).not.toContain("glsa_secret")
    expect(await running.platform.accountSource.meta(running.grafana.id)).toEqual({
      id: account.id,
      label: "grafana.example.com",
      fields: {
        url: "https://grafana.example.com",
        token: "glsa_secret",
        webhookSecret: expect.stringMatching(/^[\w-]{32}$/)
      }
    })
  })

  it("updates an account in place, keeping blank secrets and revoking the old credential", async () => {
    const running = await grafanaApp()
    const created = decode(PluginAccount)(
      (await post(running, running.accountsPath, { values: grafanaValues })).body
    )
    const before = await running.platform.accountSource.meta(running.grafana.id)
    const oldCredential = await running.credentialOf(created.id)

    const updated = await send(running, "PUT", `${running.accountsPath}/${created.id}`, {
      label: "Production",
      values: { url: "https://grafana.example.com", token: " " }
    })

    expect(updated.body).toEqual({ ...created, label: "Production" })
    expect(await running.platform.accountSource.meta(running.grafana.id, "Production")).toEqual({
      ...before,
      label: "Production"
    })
    await expect(running.vault.token(oldCredential)).rejects.toThrow()
  })

  it("removes an account and revokes its credential", async () => {
    const running = await grafanaApp()
    const created = decode(PluginAccount)(
      (await post(running, running.accountsPath, { values: grafanaValues })).body
    )
    const credential = await running.credentialOf(created.id)

    const removed = await send(running, "DELETE", `${running.accountsPath}/${created.id}`)
    const again = await send(running, "DELETE", `${running.accountsPath}/${created.id}`)

    expect([removed.status, removed.body]).toEqual([200, { removed: true }])
    expect([again.status, again.body]).toEqual([404, { error: `Account not found: ${created.id}` }])
    expect(await running.platform.accountSource.list(running.grafana.id)).toEqual([])
    await expect(running.vault.token(credential)).rejects.toThrow()
  })

  it("explains what is wrong with a request it can't save", async () => {
    const running = await grafanaApp()
    const custom = await savePluginRow(running.services.db, "Custom", { enabled: false })

    const missing = await post(running, running.accountsPath, {
      values: { url: "https://grafana.example.com" }
    })
    const plain = await post(running, `/v1/plugins/${custom.id}/accounts`, { values: {} })
    const unknown = await post(running, "/v1/plugins/nope/accounts", { values: {} })

    expect([missing.status, missing.body]).toEqual([
      400,
      { error: "Service account token is required" }
    ])
    expect([plain.status, plain.body]).toEqual([
      400,
      { error: "Custom doesn't use Codevisor accounts" }
    ])
    expect([unknown.status, unknown.body]).toEqual([404, { error: "Plugin not found: nope" }])
  })

  it("leaves methods it doesn't serve to the router", async () => {
    const running = await grafanaApp()

    const statuses = await Promise.all([
      send(running, "PATCH", running.accountsPath, {}),
      send(running, "GET", `${running.accountsPath}/account-1`),
      send(running, "GET", `${running.accountsPath}/oauth/start`)
    ])

    expect(statuses.map((response) => response.status)).toEqual([404, 404, 404])
  })

  it("lists no webhook URLs for an account while this Mac isn't linked to the cloud", async () => {
    const running = await grafanaApp()

    const ingress = await jsonRequest(running.server, `${running.accountsPath}/account-1/ingress`)

    expect(ingress.body).toEqual({ ingress: [] })
  })
})

const gmailApp = async (options: PluginServicesOptions = {}) => {
  const running = await startPluginApp(options)
  const gmail = await savePluginRow(running.services.db, "Gmail", {
    catalogId: "dev.codevisor/gmail",
    enabled: false
  })
  const start = async () =>
    decode(PluginAccountOAuthStart)(
      (
        await post(running, `/v1/plugins/${gmail.id}/accounts/oauth/start`, {
          values: { clientId: "client-1", clientSecret: "client-secret" },
          label: "Work mail"
        })
      ).body
    )
  return { ...running, gmail, start }
}

describe("plugin account OAuth routes", () => {
  it("starts Gmail sign-in with PKCE through the loopback callback", async () => {
    const running = await gmailApp()

    const started = await running.start()

    const params = new URL(started.authorizationUrl).searchParams
    expect(new URL(started.authorizationUrl).origin).toBe("https://accounts.google.com")
    expect(Object.fromEntries(params)).toMatchObject({
      client_id: "client-1",
      redirect_uri: `${localBaseUrl}/v1/plugins/oauth/callback`,
      code_challenge_method: "S256",
      access_type: "offline",
      prompt: "consent"
    })
    expect(params.get("state")).toMatch(new RegExp(`^${started.flowId}\\.local\\.`))
  })

  it("finishes sign-in from the browser callback and keeps tokens out of the API", async () => {
    const running = await gmailApp()
    const provider = await fakeOAuthProvider()
    routeGoogleTo(provider.url)
    const grant = provider.authorize((await running.start()).authorizationUrl)

    const callback = await fetch(
      `${running.server.url}/v1/plugins/oauth/callback?state=${encodeURIComponent(grant.state)}&code=${grant.code}`
    )
    const listed = await jsonRequest(running.server, `/v1/plugins/${running.gmail.id}/accounts`)

    expect([callback.status, await callback.text()]).toEqual([
      200,
      "<!doctype html><title>Codevisor</title><p>Signed in. You can return to Codevisor.</p>"
    ])
    expect(decode(PluginAccountsResponse)(listed.body).accounts).toEqual([
      expect.objectContaining({
        label: "Work mail",
        identity: "dana@example.com",
        method: "oauth2"
      })
    ])
    expect(JSON.stringify(listed.body)).not.toMatch(/access-1|refresh-1|client-secret/)
  })

  it("re-authorizes an existing account with the client it already has", async () => {
    const running = await gmailApp()
    const provider = await fakeOAuthProvider()
    routeGoogleTo(provider.url)
    const first = provider.authorize((await running.start()).authorizationUrl)
    await fetch(
      `${running.server.url}/v1/plugins/oauth/callback?state=${encodeURIComponent(first.state)}&code=${first.code}`
    )
    const [account] = decode(PluginAccountsResponse)(
      (await jsonRequest(running.server, `/v1/plugins/${running.gmail.id}/accounts`)).body
    ).accounts

    const noClient = await post(running, `/v1/plugins/${running.gmail.id}/accounts/oauth/start`, {})
    const again = await post(running, `/v1/plugins/${running.gmail.id}/accounts/oauth/start`, {
      accountId: account!.id,
      values: { clientId: "client-1" }
    })

    expect([noClient.status, noClient.body]).toEqual([
      400,
      { error: "OAuth client ID is required" }
    ])
    expect(again.status).toBe(200)
    expect(
      new URL(decode(PluginAccountOAuthStart)(again.body).authorizationUrl).searchParams.get(
        "client_id"
      )
    ).toBe("client-1")
  })

  it("refuses a callback for a sign-in it didn't start or that was cancelled", async () => {
    const running = await gmailApp()
    const started = await running.start()
    const state = new URL(started.authorizationUrl).searchParams.get("state")!

    const unknown = await jsonRequest(running.server, "/v1/plugins/oauth/callback?code=abc")
    const cancelled = await jsonRequest(
      running.server,
      `/v1/plugins/oauth/callback?state=${encodeURIComponent(state)}&error=access_denied`
    )

    expect([unknown.status, unknown.body]).toEqual([
      400,
      { error: "This sign-in link expired. Start again." }
    ])
    expect([cancelled.status, cancelled.body]).toEqual([
      400,
      { error: "Sign-in was cancelled (access_denied)" }
    ])
  })
})

describe("plugin routes without the plugin platform", () => {
  it("answers 501 when this server runs without plugins", async () => {
    const server = await startWithoutPlugins()

    const responses = await Promise.all([
      jsonRequest(server, "/v1/plugins/server-1/accounts"),
      jsonRequest(server, "/v1/plugins/server-1/accounts/account-1/ingress"),
      jsonRequest(server, "/v1/plugins/oauth/callback?state=s&code=c")
    ])

    expect(responses.map((response) => [response.status, response.body])).toEqual([
      [501, { error: "Plugins unavailable" }],
      [501, { error: "Plugin events unavailable" }],
      [501, { error: "Plugins unavailable" }]
    ])
  })
})

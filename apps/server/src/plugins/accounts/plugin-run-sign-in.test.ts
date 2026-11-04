import { dirname } from "node:path"

import type { PluginAccountSpec } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { manualOAuthClock, sharedCoordinator } from "../../infra/mcp-oauth-test-support.js"
import { mcpCredentialVault } from "../../infra/shared-account-storage.js"
import { makeServices } from "../../test-support.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import { makePluginAccountStore } from "./plugin-account-store.js"
import { makePluginAccounts } from "./plugin-accounts.js"
import type { PluginSignIn, PluginSignInRequest } from "./plugin-run-sign-in.js"

const storeSpec: PluginAccountSpec = {
  label: "Shopify store",
  oauth: { provider: "shopify", client: "plugin", scopes: ["read_products", "write_products"] },
  fields: [{ key: "store", label: "Store address", type: "string", required: true }]
}

const pluginRunFixture = async (pluginSignIn?: PluginSignIn) => {
  const { services } = await makeServices("server-a")
  const clock = manualOAuthClock(Date.UTC(2026, 10, 4, 9))
  const vault = mcpCredentialVault(
    dirname(services.attachments.root),
    sharedCoordinator(clock).machine("server-a"),
    clock.now
  )
  const server = await savePluginRow(services.db, "Shopify", { catalogId: "dev.codevisor/shopify" })
  const saved = Promise.withResolvers<void>()
  const accounts = makePluginAccounts({
    store: makePluginAccountStore(services.db, "server-a", clock.now),
    vault,
    server: async () => server,
    spec: () => storeSpec,
    redirects: { prepare: () => Promise.reject(new Error("no OAuth redirect for plugin sign-in")) },
    ...(pluginSignIn === undefined ? {} : { pluginSignIn }),
    onChanged: () => saved.resolve()
  })
  return { accounts, server, saved: saved.promise }
}

const heldSignIn = () => {
  const requests: Array<PluginSignInRequest> = []
  const finished = Promise.withResolvers<{ identity?: string; label?: string }>()
  const signIn: PluginSignIn = (request) => {
    requests.push(request)
    return finished.promise
  }
  return { requests, finished, signIn }
}

describe("plugin-run sign-in", () => {
  it("hands the sign-in to the plugin and adds the account once the plugin finishes", async () => {
    const held = heldSignIn()
    const { accounts, server, saved } = await pluginRunFixture(held.signIn)

    const started = await accounts.startOAuth(server.id, {
      values: { store: "acme-goods.myshopify.com" }
    })
    const whileSigningIn = await accounts.list(server.id)
    held.finished.resolve({ label: "acme-goods.myshopify.com", identity: "owner@acme.test" })
    await saved

    expect(started).toEqual({ flowId: expect.any(String) })
    expect(held.requests).toEqual([
      {
        serverId: server.id,
        values: { store: "acme-goods.myshopify.com" },
        scopes: ["read_products", "write_products"]
      }
    ])
    expect(whileSigningIn).toEqual([])
    expect(await accounts.list(server.id)).toEqual([
      expect.objectContaining({
        label: "acme-goods.myshopify.com",
        identity: "owner@acme.test",
        method: "oauth2",
        values: { store: "acme-goods.myshopify.com" },
        status: "ok"
      })
    ])
    expect(await accounts.context(server.id)).toEqual(
      expect.objectContaining({ fields: { store: "acme-goods.myshopify.com" } })
    )
  })

  it("refuses when this machine can't run plugin sign-ins", async () => {
    const { accounts, server } = await pluginRunFixture()

    await expect(
      accounts.startOAuth(server.id, { values: { store: "acme-goods.myshopify.com" } })
    ).rejects.toMatchObject({ status: 501, message: "Shopify can't sign in on this machine" })
  })
})

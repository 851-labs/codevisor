import { describe, expect, it } from "vitest"

import { PluginAccount, PluginCatalogEntry, decode } from "./index.js"

describe("plugin API", () => {
  it("decodes a catalog entry with an OAuth account spec and capability digest", () => {
    const entry = decode(PluginCatalogEntry)({
      id: "codevisor.gmail",
      name: "Gmail",
      description: "Read, search and reply to email",
      publisher: "Codevisor",
      version: "1.0.0",
      source: "first-party",
      transport: "stdio",
      install: { kind: "bundled" },
      accounts: {
        label: "Google account",
        oauth: {
          provider: "google",
          authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
          tokenUrl: "https://oauth2.googleapis.com/token",
          scopes: ["https://www.googleapis.com/auth/gmail.modify"],
          client: "byo"
        },
        fields: [{ key: "clientId", label: "Client ID", type: "string", required: true }]
      },
      capabilities: {
        tools: [{ name: "reply", effects: "external-write" }],
        events: [{ name: "message.received" }],
        skills: [],
        panes: [],
        ingress: []
      }
    })
    expect(entry.accounts?.oauth?.client).toBe("byo")
    expect(entry.capabilities.tools[0]?.effects).toBe("external-write")
  })

  it("rejects an account with an unknown method", () => {
    const account = {
      id: "acc-1",
      plugin: "Grafana",
      values: { url: "https://grafana.example" },
      secretsSet: ["token"],
      status: "ok",
      createdAt: "2026-10-27T00:00:00.000Z"
    }
    expect(decode(PluginAccount)({ ...account, method: "fields" }).secretsSet).toEqual(["token"])
    expect(() => decode(PluginAccount)({ ...account, method: "magic" })).toThrow()
  })
})

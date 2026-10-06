import { expect, it, vi } from "vitest"

import { makeOpenCode2Accounts } from "./accounts.js"
import { makeOpenCodeServerPool } from "./pool.js"
import type { OpenCodeServer } from "./server.js"

it("lists a profile's providers from its own OpenCode 2 server, started once per data directory", async () => {
  const request = vi.fn(async (_path: string, init?: { readonly location?: string }) => ({
    data: [{ id: "anthropic", name: "Anthropic", methods: [{ type: "key" }], connections: [] }],
    location: init?.location
  }))
  const server = { url: "http://oc", request, stop: vi.fn(async () => undefined) }
  const start = vi.fn(async () => server as unknown as OpenCodeServer)
  const accounts = makeOpenCode2Accounts({ pool: makeOpenCodeServerPool(), start })
  const profile = {
    command: "/bin/opencode",
    cwd: "/home/me",
    env: { XDG_DATA_HOME: "/profiles/work" }
  }

  const providers = await accounts.providers(profile)
  await accounts.providers(profile)

  expect(providers).toEqual([
    {
      id: "anthropic",
      name: "Anthropic",
      methods: [{ id: "key", type: "api", label: "API Key", prompts: [] }]
    }
  ])
  expect(start).toHaveBeenCalledOnce()
  expect(start).toHaveBeenCalledWith({
    command: "/bin/opencode",
    env: profile.env,
    cwd: "/home/me"
  })
  expect(request).toHaveBeenCalledWith("/api/integration", { location: "/home/me" })
})

it("replaces only Codevisor's own credentials when syncing a profile", async () => {
  const calls: Array<[string, unknown]> = []
  const request = vi.fn(async (path: string, init?: unknown) => {
    calls.push([path, init])
    return path === "/api/credential" && init === undefined
      ? { data: [{ id: "codevisor-openai" }, { id: "codevisor-xai" }, { id: "users-own-key" }] }
      : undefined
  })
  const server = { url: "http://oc", request, stop: vi.fn(async () => undefined) }
  const accounts = makeOpenCode2Accounts({
    pool: makeOpenCodeServerPool(),
    start: async () => server as unknown as OpenCodeServer
  })
  const openai = {
    id: "codevisor-openai",
    integrationID: "openai",
    value: {
      type: "oauth",
      methodID: "chatgpt-browser",
      refresh: "codevisor:cap",
      access: "a",
      expires: 1
    }
  }
  await accounts.syncCredentials({ command: "/bin/opencode", cwd: "/home", env: {} }, [openai])
  expect(calls.slice(1)).toEqual([
    ["/api/credential/codevisor-openai", { method: "DELETE" }],
    ["/api/credential/codevisor-xai", { method: "DELETE" }],
    ["/api/credential", { body: { ...openai, label: "Codevisor", activate: true } }]
  ])
})

it("signs a profile out of one provider, whichever credentials it holds", async () => {
  const calls: Array<[string, unknown]> = []
  const request = vi.fn(async (path: string, init?: unknown) => {
    calls.push([path, init])
    return init === undefined
      ? {
          data: [
            { id: "a", integrationID: "openai" },
            { id: "b", integrationID: "xai" },
            { id: "c d", integrationID: "openai" }
          ]
        }
      : undefined
  })
  const server = { url: "http://oc", request, stop: vi.fn(async () => undefined) }
  const accounts = makeOpenCode2Accounts({
    pool: makeOpenCodeServerPool(),
    start: async () => server as unknown as OpenCodeServer
  })
  await accounts.removeIntegration({ command: "/bin/opencode", cwd: "/home", env: {} }, "openai")
  expect(calls.slice(1)).toEqual([
    ["/api/credential/a", { method: "DELETE" }],
    ["/api/credential/c%20d", { method: "DELETE" }]
  ])
})

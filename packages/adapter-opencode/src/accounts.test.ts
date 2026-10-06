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

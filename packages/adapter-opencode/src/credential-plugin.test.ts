import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

import { afterEach, expect, it, onTestFinished, vi } from "vitest"

import { openCodeCredentialPluginFiles } from "./credential-plugin.js"

interface Registration {
  readonly integrationID: string
  readonly method: { readonly id?: string; readonly type: string }
  readonly authorize: () => Promise<unknown>
  readonly refresh: (credential: Record<string, unknown>) => Promise<Record<string, unknown>>
}

afterEach(() => {
  vi.unstubAllGlobals()
})

/// Loads the generated plugin and runs its setup against OpenCode's
/// built-in methods, returning what it registered.
const load = async (options: unknown) => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-opencode-plugin-"))
  onTestFinished(() => rm(directory, { recursive: true, force: true }))
  for (const [name, content] of Object.entries(openCodeCredentialPluginFiles))
    await writeFile(join(directory, name), content)
  const plugin = (await import(pathToFileURL(join(directory, "index.mjs")).href)) as {
    default: { id: string; setup: (ctx: unknown) => Promise<void> }
  }
  const builtIn: Record<string, ReadonlyArray<{ id?: string; type: string }>> = {
    openai: [
      { type: "key" },
      { id: "chatgpt-token-sharing", type: "oauth" },
      { id: "chatgpt-browser", type: "oauth" }
    ],
    "github-copilot": [{ id: "device", type: "oauth" }]
  }
  const registered: Registration[] = []
  await plugin.default.setup({
    options,
    integration: {
      transform: async (edit: (editor: unknown) => void) => {
        edit({
          method: {
            list: (integrationID: string) => builtIn[integrationID] ?? [],
            update: (registration: Registration) => registered.push(registration)
          }
        })
      }
    }
  })
  return { id: plugin.default.id, registered }
}

it("refreshes Codevisor-shared sign-ins through the broker, never with a real refresh token", async () => {
  const fetch = vi.fn(async (_url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body)) as { rejectedAccessToken?: string }
    return Response.json({
      credential: {
        access: `fresh-for-${body.rejectedAccessToken}`,
        expires: 9_000,
        refresh: "never"
      }
    })
  })
  vi.stubGlobal("fetch", fetch)
  const { id, registered } = await load({ broker: "http://127.0.0.1:9/harness/provider-token" })

  expect(id).toBe("codevisor.shared-credentials")
  // Only methods OpenCode actually has here; xAI isn't installed in this fixture.
  expect(registered.map((entry) => [entry.integrationID, entry.method.id])).toEqual([
    ["openai", "chatgpt-browser"]
  ])
  const [openai] = registered
  const stored = {
    type: "oauth",
    methodID: "chatgpt-browser",
    refresh: "codevisor:capability-1",
    access: "stale",
    expires: 1,
    metadata: { accountID: "acct" }
  }
  expect(await openai!.refresh(stored)).toEqual({
    ...stored,
    access: "fresh-for-stale",
    expires: 9_000
  })
  const [url, init] = fetch.mock.calls[0]!
  expect(url).toBe("http://127.0.0.1:9/harness/provider-token")
  expect(new Headers(init.headers).get("authorization")).toBe("Bearer capability-1")

  await expect(openai!.refresh({ ...stored, refresh: "a-real-refresh-token" })).rejects.toThrow(
    "Sign in to this provider again"
  )
  expect(fetch).toHaveBeenCalledOnce()
  fetch.mockResolvedValueOnce(new Response(null, { status: 401 }))
  await expect(openai!.refresh(stored)).rejects.toThrow("Reconnect this account in Codevisor.")
  await expect(openai!.authorize()).rejects.toThrow("from Codevisor's OpenCode accounts")
})

it("refuses to load without its broker", async () => {
  await expect(load({})).rejects.toThrow("needs its broker URL")
})

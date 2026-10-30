import { afterEach, describe, expect, it, vi } from "vitest"

import { makeCodevisorProvider } from "./codevisor-provider.js"

interface SentRequest {
  readonly method: string
  readonly path: string
  readonly body?: unknown
}

const context = { sessionId: "caller", projectId: "project" }

const fakeServer = (answers: Readonly<Record<string, unknown>>): SentRequest[] => {
  const sent: SentRequest[] = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: URL, init: RequestInit) => {
      const path = `${url.pathname}${url.search}`
      const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined
      sent.push({ method: init.method!, path, ...(body === undefined ? {} : { body }) })
      const answer = answers[`${init.method} ${url.pathname}`]
      if (answer === undefined) return new Response(null, { status: 204 })
      return new Response(JSON.stringify(answer), {
        headers: { "content-type": "application/json" }
      })
    })
  )
  return sent
}

const provider = () =>
  makeCodevisorProvider(
    () => "http://localhost:5000",
    async () => "token"
  )

const resultOf = async (tool: string, args: Record<string, unknown>): Promise<unknown> => {
  const result = await provider().invoke(context, tool, args)
  const first = result.content[0]
  const text = first?.type === "text" ? first.text : undefined
  if (result.isError === true) throw new Error(text)
  return text === undefined ? undefined : JSON.parse(text)
}

describe("sandbox tools", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("manage providers by accountId without sending anything but the request", async () => {
    const account = { id: "acct", provider: "vercel", values: {}, secretsSet: ["token"] }
    const sent = fakeServer({
      "GET /v1/sandbox-accounts": { accounts: [account] },
      "POST /v1/sandbox-accounts": account,
      "PUT /v1/sandbox-accounts/acct": account
    })

    const listed = await resultOf("sandboxes.providers_list", {})
    const created = await resultOf("sandboxes.providers_create", {
      provider: "vercel",
      values: { token: "secret-token" }
    })
    await resultOf("sandboxes.providers_update", {
      accountId: "acct",
      provider: "vercel",
      label: "Work",
      values: {}
    })
    await resultOf("sandboxes.providers_delete", { accountId: "acct", confirm: true })

    expect(listed).toEqual({ items: [{ ...account, id: undefined, accountId: "acct" }] })
    expect(created).toMatchObject({ accountId: "acct", secretsSet: ["token"] })
    expect(sent).toEqual([
      { method: "GET", path: "/v1/sandbox-accounts" },
      {
        method: "POST",
        path: "/v1/sandbox-accounts",
        body: { provider: "vercel", values: { token: "secret-token" } }
      },
      {
        method: "PUT",
        path: "/v1/sandbox-accounts/acct",
        body: { provider: "vercel", label: "Work", values: {} }
      },
      { method: "DELETE", path: "/v1/sandbox-accounts/acct" }
    ])
  })

  it("manage profiles with their CPU and memory values by profileId", async () => {
    const profile = { id: "small", name: "Small", provider: "tart", values: { cpu: 4 } }
    const sent = fakeServer({
      "GET /v1/sandbox-profiles": { profiles: [profile] },
      "GET /v1/sandbox-profiles/availability": { profiles: [{ profileId: "small" }] },
      "POST /v1/sandbox-profiles": profile,
      "PUT /v1/sandbox-profiles/small": profile
    })
    const save = {
      name: "Small",
      provider: "tart",
      accountId: "mac",
      values: { cpu: 4, memoryGiB: 8 }
    }

    const listed = await resultOf("sandboxes.profiles_list", {})
    const availability = await resultOf("sandboxes.profiles_availability", {})
    const created = await resultOf("sandboxes.profiles_create", save)
    await resultOf("sandboxes.profiles_update", { profileId: "small", ...save })
    await resultOf("sandboxes.profiles_delete", { profileId: "small", confirm: true })

    expect(listed).toEqual({ items: [{ ...profile, id: undefined, profileId: "small" }] })
    expect(availability).toEqual({ profiles: [{ profileId: "small" }] })
    expect(created).toMatchObject({ profileId: "small" })
    expect(sent).toEqual([
      { method: "GET", path: "/v1/sandbox-profiles" },
      { method: "GET", path: "/v1/sandbox-profiles/availability" },
      { method: "POST", path: "/v1/sandbox-profiles", body: save },
      { method: "PUT", path: "/v1/sandbox-profiles/small", body: save },
      { method: "DELETE", path: "/v1/sandbox-profiles/small" }
    ])
  })

  it("list vendors, start, follow, retry and destroy sandboxes by sandboxId", async () => {
    const sandbox = { id: "box", state: "creating" }
    const sent = fakeServer({
      "GET /v1/sandbox-providers": { providers: [], capabilities: [], maximums: {} },
      "GET /v1/sandboxes": [sandbox],
      "GET /v1/sandboxes/box": sandbox,
      "GET /v1/sandboxes/box/log": { lines: [{ machineId: "box", line: "Booting" }] },
      "POST /v1/sandboxes": sandbox,
      "POST /v1/sandboxes/box/retry": sandbox,
      "POST /v1/sandboxes/box/wait": { ...sandbox, timedOut: true },
      "POST /v1/sandboxes/box/wake": { ...sandbox, power: "waking" },
      "DELETE /v1/sandboxes/box": { destroyed: "box" }
    })

    await resultOf("sandboxes.vendors", {})
    const listed = await resultOf("sandboxes.list", {})
    const one = await resultOf("sandboxes.get", { sandboxId: "box" })
    const log = await resultOf("sandboxes.log", { sandboxId: "box", last: 50 })
    const created = await resultOf("sandboxes.create", {
      profileId: "small",
      projectId: "project",
      harnessId: "codex"
    })
    const retried = await resultOf("sandboxes.retry", { sandboxId: "box" })
    const waited = await resultOf("sandboxes.wait", { sandboxId: "box", timeoutMs: 5000 })
    const woken = await resultOf("sandboxes.wake", { sandboxId: "box" })
    await resultOf("sandboxes.destroy", { sandboxId: "box", confirm: true })

    expect([listed, one, created, retried]).toEqual([
      { items: [{ sandboxId: "box", state: "creating" }] },
      { sandboxId: "box", state: "creating" },
      { sandboxId: "box", state: "creating" },
      { sandboxId: "box", state: "creating" }
    ])
    expect(waited).toEqual({ sandboxId: "box", state: "creating", timedOut: true })
    expect(woken).toEqual({ sandboxId: "box", state: "creating", power: "waking" })
    expect(log).toEqual({ lines: [{ machineId: "box", line: "Booting" }] })
    expect(sent).toEqual([
      { method: "GET", path: "/v1/sandbox-providers" },
      { method: "GET", path: "/v1/sandboxes" },
      { method: "GET", path: "/v1/sandboxes/box" },
      { method: "GET", path: "/v1/sandboxes/box/log?last=50" },
      {
        method: "POST",
        path: "/v1/sandboxes",
        body: { profileId: "small", projectId: "project", harnessId: "codex" }
      },
      { method: "POST", path: "/v1/sandboxes/box/retry" },
      { method: "POST", path: "/v1/sandboxes/box/wait", body: { timeoutMs: 5000 } },
      { method: "POST", path: "/v1/sandboxes/box/wake" },
      { method: "DELETE", path: "/v1/sandboxes/box" }
    ])
  })

  it("require confirm before deleting a provider, a profile or a sandbox", async () => {
    const sent = fakeServer({})

    const deletions: ReadonlyArray<readonly [string, Record<string, unknown>]> = [
      ["sandboxes.providers_delete", { accountId: "acct" }],
      ["sandboxes.profiles_delete", { profileId: "small" }],
      ["sandboxes.destroy", { sandboxId: "box" }]
    ]

    const refused = await Promise.all(
      deletions.map(([tool, args]) => resultOf(tool, args).catch((error: unknown) => String(error)))
    )

    expect(refused).toEqual([
      expect.stringContaining("requires confirm: true"),
      expect.stringContaining("requires confirm: true"),
      expect.stringContaining("requires confirm: true")
    ])
    expect(sent).toEqual([])
  })

  it("pass a sandbox profile through agents.start", async () => {
    const sent = fakeServer({ "POST /v1/agents": { sandboxId: "box", state: "creating" } })

    await resultOf("agents.start", {
      title: "Fix it",
      prompt: "Fix the bug",
      isolation: "project",
      sandboxProfile: "Small"
    })

    expect(sent[0]?.body).toEqual({
      title: "Fix it",
      prompt: "Fix the bug",
      isolation: "project",
      sandboxProfile: "Small",
      callerAgentId: "caller"
    })
  })
})

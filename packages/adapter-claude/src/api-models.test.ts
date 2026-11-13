import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk"
import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import { definition, FakeQuery, makeProvider, recordsValue, run } from "./test-support.js"

afterEach(() => vi.restoreAllMocks())

const proxyUrl = "http://127.0.0.1:4000/harness/claude"

const signedIn: HarnessAccountContext = {
  id: "shared-account",
  profileKind: "managed",
  env: { CLAUDE_CODE_OAUTH_TOKEN: "oauth-token", ANTHROPIC_BASE_URL: proxyUrl }
}

const cliModels: Array<ModelInfo> = [
  {
    value: "opus",
    resolvedModel: "claude-opus-5-5",
    displayName: "Opus",
    description: "",
    supportsFastMode: true
  },
  {
    value: "claude-fable-5-1[1m]",
    resolvedModel: "claude-fable-5-1",
    displayName: "Fable",
    description: "Fable 5.1 · Most capable",
    supportsFastMode: true
  }
]

const effort = (...levels: Array<string>) =>
  Object.fromEntries(levels.map((level) => [level, { supported: true }]))

const anthropicModels = {
  data: [
    {
      id: "claude-fable-5-1",
      display_name: "Claude Fable 5.1",
      line: "fable",
      lifecycle: "active",
      created_at: "2026-08-28T00:00:00Z",
      capabilities: { effort: effort("low", "high") }
    },
    {
      id: "claude-fable-5-2",
      display_name: "Claude Fable 5.2",
      line: "fable",
      lifecycle: "active",
      created_at: "2026-11-09T00:00:00Z",
      capabilities: { effort: effort("low", "medium", "high", "xhigh", "max") }
    },
    {
      id: "claude-sonnet-4-5-20250929",
      display_name: "Claude Sonnet 4.5",
      line: "sonnet",
      lifecycle: "deprecated",
      created_at: "2025-09-29T00:00:00Z",
      capabilities: { effort: effort("low") }
    },
    {
      id: "claude-haiku-4-5-20251001",
      display_name: "Claude Haiku 4.5",
      line: "haiku",
      lifecycle: "active",
      created_at: "2025-10-15T00:00:00Z",
      capabilities: { effort: {} }
    },
    {
      id: "claude-opus-5-5",
      display_name: "Claude Opus 5.5",
      line: "opus",
      lifecycle: "active",
      created_at: "2026-09-21T00:00:00Z",
      capabilities: { effort: effort("low", "high") }
    }
  ]
}

const startWith = async (account: HarnessAccountContext, response: () => Promise<Response>) => {
  const fake = new FakeQuery()
  vi.spyOn(fake, "supportedModels").mockResolvedValue(cliModels)
  const request = vi.fn<typeof fetch>(response)
  const provider = makeProvider(fake, undefined, undefined, { fetch: request })
  const created = await run(provider.createSession(definition, "/tmp", async () => {}, account))
  return { created, request }
}

const optionsOf = (configOptions: unknown, id: string) =>
  recordsValue(configOptions).find((option) => option.id === id)?.options

describe("Claude model picker", () => {
  it("lists the newest model in each line from Anthropic, through the account's proxy", async () => {
    const { created, request } = await startWith(signedIn, async () =>
      Response.json(anthropicModels)
    )

    expect(optionsOf(created.metadata.configOptions, "model")).toEqual([
      { name: "Opus 5.5", value: "claude-opus-5-5" },
      { name: "Fable 5.2", value: "claude-fable-5-2" },
      { name: "Haiku 4.5", value: "claude-haiku-4-5-20251001" }
    ])
    const [url, init] = request.mock.calls[0]!
    expect(url).toBe(`${proxyUrl}/v1/models?limit=1000`)
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer oauth-token")

    const onFable = await run(created.handle.setConfigOption("model", "claude-fable-5-2"))
    expect(optionsOf(onFable, "effort")).toHaveLength(5)
    expect(optionsOf(onFable, "speed")).toBeUndefined()
    const onOpus = await run(created.handle.setConfigOption("model", "claude-opus-5-5"))
    expect(optionsOf(onOpus, "speed")).toHaveLength(2)
  })

  it.each([
    ["Anthropic's model list fails", signedIn, 1],
    ["the account holds no Anthropic credentials", { ...signedIn, env: {} }, 0]
  ])("keeps the CLI's own list when %s", async (_case, account, requests) => {
    const { created, request } = await startWith(account, async () =>
      Response.json({}, { status: 500 })
    )

    expect(optionsOf(created.metadata.configOptions, "model")).toEqual([
      { name: "Opus", value: "opus" },
      { name: "Fable 5.1", value: "claude-fable-5-1[1m]" }
    ])
    expect(request).toHaveBeenCalledTimes(requests)
  })
})

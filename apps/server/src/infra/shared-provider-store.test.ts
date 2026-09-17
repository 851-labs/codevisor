import { parseProviderOAuth } from "@codevisor/harness-manager"
import { describe, expect, it, afterEach, beforeEach, vi } from "vitest"

import { fleet } from "./shared-accounts-test-support.js"
import { providerRecord, providerSlot } from "./shared-provider-store.js"

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(1000)
})
afterEach(() => vi.useRealTimers())
const record = {
  harnessId: "pi",
  profileId: "default",
  providerId: "anthropic",
  subject: "user",
  organizationId: "team",
  credential: { id: "credential-identifier", key: "a".repeat(43) }
}

describe("provider account replica validation", () => {
  it("ignores malformed records and never uses a credential reference under a different provider slot", async () => {
    for (const value of [
      null,
      "text",
      [],
      {},
      { ...record, harnessId: "unknown" },
      { ...record, profileId: 1 },
      { ...record, providerId: 1 },
      { ...record, subject: null },
      { ...record, organizationId: 1 },
      { ...record, credential: null },
      { ...record, credential: { id: 1, key: "a".repeat(43) } },
      { ...record, credential: { id: "invalid", key: "a".repeat(43) } },
      { ...record, credential: { id: record.credential.id, key: 1 } },
      { ...record, credential: { id: record.credential.id, key: "invalid" } }
    ])
      expect(providerRecord(value)).toBeUndefined()
    expect(providerRecord(record)).toEqual(record)
    const host = await fleet().machine("malformed")
    const slot = providerSlot("pi", "default", "anthropic")
    await host.shared.store.writeProvider(slot, { ...record, providerId: "openai-codex" })
    expect(await host.shared.providers.store.get(slot)).toBeUndefined()
    for (const key of [
      "provider:invalid",
      "provider:{}",
      "provider:[]",
      'provider:["pi","default",1]',
      'provider:["pi","default","anthropic","extra"]'
    ])
      await host.shared.store.writeProvider(key, false)
    expect(await host.shared.providers.store.knownProviders("pi", "default")).toEqual(["anthropic"])
  })

  it("keeps durable Copilot discovery idempotent and revokes only a removed local override", async () => {
    const host = await fleet().machine("durable")
    const bundle = parseProviderOAuth(
      "opencode",
      "github-copilot",
      {
        type: "oauth",
        access: "irrelevant",
        refresh: "github-token",
        expires: 0,
        accountId: "team"
      },
      "external"
    )!
    const value = { ...bundle, harnessId: "opencode" as const }
    const store = host.shared.providers.store
    await store.save(value, "default", false, false)
    const slot = providerSlot("opencode", "default", "github-copilot")
    const original = (await store.get(slot))!
    await store.save(value, "default", false, false)
    expect((await store.get(slot))?.credential.id).toBe(original.credential.id)
    expect((await host.vault.token(original.credential)).accessToken).toBe("github-token")
    await store.save(
      { ...value, subject: "different", accessToken: "local" },
      "default",
      true,
      false
    )
    const local = (await store.get(slot))!
    await store.remove("opencode", "default", "github-copilot")
    await expect(host.vault.token(local.credential)).rejects.toThrow("signed out")
    expect((await host.vault.token(original.credential)).accessToken).toBe("github-token")
    await store.save(
      { ...value, subject: "local-only", accessToken: "local-only" },
      "default",
      true,
      false
    )
    const localOnly = (await store.get(slot))!
    await host.shared.store.writeProvider(slot, null, true)
    // A local-only account does not depend on the global selection existing.
    expect(await store.remove("opencode", "default", "github-copilot")).toBe(true)
    await expect(host.vault.token(localOnly.credential)).rejects.toThrow("signed out")
  })
})

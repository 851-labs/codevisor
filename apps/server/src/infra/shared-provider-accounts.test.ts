import { readFile, stat, realpath, writeFile, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { HarnessAccount } from "@codevisor/api"
import { atomicWriteJson } from "@codevisor/harness-manager"
import { afterEach, beforeEach, describe, expect, it, vi, onTestFinished } from "vitest"

import { run } from "../test-support.js"
import { fleet } from "./shared-accounts-test-support.js"
import { providerSlot } from "./shared-provider-store.js"

const jwt = (sub: string) =>
  `header.${Buffer.from(JSON.stringify({ sub })).toString("base64url")}.signature`
const credential = (sub = "alice") => ({
  type: "oauth",
  access: jwt(sub),
  refresh: `refresh-${sub}`,
  expires: 3_600_000
})
const account = (harnessId: string) =>
  ({
    id: `${harnessId}-default`,
    harnessId,
    profileKind: "default" as const,
    label: "Default",
    authState: "authenticated" as const,
    canLogin: true,
    canLogout: true,
    isActive: true
  }) satisfies HarnessAccount
const json = async (path: string) =>
  JSON.parse(await readFile(path, "utf8")) as Record<string, Record<string, unknown>>
beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(1000)
})
afterEach(() => {
  vi.useRealTimers()
})

describe("provider accounts across machines", () => {
  it("discovers Grok's native OAuth document and makes it usable on a fresh machine", async () => {
    const { machine, sync } = fleet()
    const a = await machine("grok-source"),
      b = await machine("grok-destination")
    await atomicWriteJson(join(a.dataDir, ".grok", "auth.json"), {
      "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
        auth_mode: "oidc",
        key: jwt("grok-user"),
        refresh_token: "native-grok-refresh",
        expires_at: new Date(3_600_000).toISOString(),
        oidc_issuer: "https://auth.x.ai",
        oidc_client_id: "b1a00492-073a-47ea-816f-4c329264a828",
        user_id: "grok-user",
        create_time: new Date(0).toISOString()
      }
    })
    await a.shared.providers.reconcile()
    expect(await a.shared.providers.configured("grok-build", "default")).toEqual(["xai"])
    await sync(a, b)
    expect(await b.shared.providers.configured("grok-build", "default")).toEqual(["xai"])
    const row = await b.shared.providers.store.get(providerSlot("grok-build", "default", "xai"))
    const bundle = await b.vault.token(row!.credential)
    expect(bundle).toMatchObject({
      accessToken: jwt("grok-user"),
      ownership: "external",
      subject: "grok-user"
    })
    expect(bundle.refreshToken).toBeUndefined()
    const context = await b.shared.providers.context(account("grok-build"), {
      id: "grok-build-default",
      profileKind: "default"
    })
    expect(context.env?.GROK_AUTH_PROVIDER_COMMAND).toContain("token.sh")
  })

  it("deduplicates a joining machine's existing account and respects a global sign-out on first discovery", async () => {
    const { machine, sync } = fleet()
    const a = await machine("join-a"),
      b = await machine("join-b"),
      c = await machine("join-c")
    await atomicWriteJson(join(a.dataDir, ".pi", "agent", "auth.json"), { anthropic: credential() })
    await a.shared.providers.reconcile()
    await sync(a, b)
    await atomicWriteJson(join(b.dataDir, ".pi", "agent", "auth.json"), { anthropic: credential() })
    await b.shared.providers.reconcile()
    const slot = providerSlot("pi", "default", "anthropic")
    expect((await b.shared.providers.store.get(slot))?.credential).toEqual(
      (await a.shared.providers.store.get(slot))?.credential
    )
    await a.shared.providers.remove("pi", "default", "anthropic", true)
    await sync(a, c)
    await atomicWriteJson(join(c.dataDir, ".pi", "agent", "auth.json"), {
      anthropic: { ...credential(), accountId: "org" }
    })
    await c.shared.providers.reconcile()
    expect(await c.shared.providers.configured("pi", "default")).toEqual([])
    // Re-observing a disabled source also cannot recreate the deleted grant.
    await c.shared.providers.reconcile()
  })

  it("preserves local API keys and Pi's relative resources after changing authentication", async () => {
    const host = await fleet().machine("resources")
    const source = join(host.dataDir, ".pi", "agent")
    await atomicWriteJson(join(source, "settings.json"), {
      extensions: ["./custom.ts", "/absolute.ts", "~/user.ts", { source: "package" }],
      skills: ["./skills-extra"],
      theme: "custom"
    })
    await host.shared.providers.capture("pi", "default", "anthropic", credential())
    expect(await host.shared.providers.staticOverrides("pi")).toEqual([])
    expect(await host.shared.providers.disabled("pi", "default")).toEqual([])
    await host.shared.providers.remove("pi", "default", "anthropic")
    expect(await host.shared.providers.remove("pi", "default", "openai")).toBe(false)
    expect(await host.shared.providers.staticOverrides("pi")).toEqual(["anthropic", "openai"])
    expect(await host.shared.providers.disabled("pi", "default")).toEqual(["anthropic", "openai"])
    await atomicWriteJson(join(source, "auth.json"), {
      anthropic: { type: "api_key", key: "local-key" }
    })
    const context = await host.shared.providers.context(account("pi"), {
      id: "pi-default",
      profileKind: "default"
    })
    const root = context.env!.PI_CODING_AGENT_DIR!
    expect((await json(join(root, "auth.json"))).anthropic).toEqual({
      type: "api_key",
      key: "local-key"
    })
    expect(await json(join(root, "settings.json"))).toMatchObject({
      extensions: [
        join(source, "custom.ts"),
        "/absolute.ts",
        "~/user.ts",
        { source: "package" },
        join(source, "extensions")
      ],
      skills: [join(source, "skills-extra")],
      theme: "custom"
    })
    expect(await realpath(join(root, "sessions"))).toBe(await realpath(join(source, "sessions")))
    await atomicWriteJson(join(source, "auth.json"), {
      custom: { type: "oauth", refresh: "owned-by-plugin" }
    })
    await expect(
      host.shared.providers.context(account("pi"), { id: "pi-default", profileKind: "default" })
    ).rejects.toThrow("separate profile")
  })

  it("discovers first-party Grok at a custom location and preserves configuration and conversations", async () => {
    const root = await mkdtemp(join(tmpdir(), "provider-custom-paths-"))
    onTestFinished(() => rm(root, { recursive: true, force: true }))
    const host = await fleet().machine("custom", undefined, {
      environment: async () => ({
        PI_CODING_AGENT_DIR: join(root, "pi"),
        XDG_DATA_HOME: join(root, "data"),
        GROK_HOME: join(root, "grok")
      })
    })
    await atomicWriteJson(join(root, "grok", "auth.json"), {
      default: {
        auth_mode: "oidc",
        key: "grok-access",
        refresh_token: "terminal-refresh",
        expires_at: new Date(3_600_000).toISOString(),
        oidc_issuer: "https://auth.x.ai",
        oidc_client_id: "b1a00492-073a-47ea-816f-4c329264a828",
        user_id: "user",
        organization_id: "team"
      }
    })
    await writeFile(join(root, "grok", "config.toml"), 'model = "grok-4"')
    await host.shared.providers.reconcile()
    const row = (await host.shared.providers.store.get(
      providerSlot("grok-build", "default", "xai")
    ))!
    expect(await host.vault.token(row.credential)).toMatchObject({
      ownership: "external",
      organizationId: "team"
    })
    const base = { id: "grok-build-default", profileKind: "default" as const }
    const context = await host.shared.providers.context(account("grok-build"), base)
    expect(await readFile(join(context.env!.GROK_HOME!, "config.toml"), "utf8")).toBe(
      'model = "grok-4"'
    )
    expect(await realpath(join(context.env!.GROK_HOME!, "sessions"))).toBe(
      await realpath(join(root, "grok", "sessions"))
    )
    await host.shared.providers.context(account("grok-build"), base)
  })

  it("preserves OpenCode's database and configured plugins in the managed runtime", async () => {
    const host = await fleet().machine("opencode-resources")
    await run(host.db.saveHarnessAccount(account("opencode")))
    await host.shared.providers.capture("opencode", "default", "openai", credential())
    const base = {
      id: "opencode-default",
      profileKind: "default" as const,
      env: {
        OPENCODE_CONFIG_CONTENT: JSON.stringify({ plugin: ["custom-plugin"], model: "xai/grok-4" }),
        OPENCODE_DB: "work.db"
      }
    }
    const context = await host.shared.providers.context(account("opencode"), base)
    expect(JSON.parse(context.env!.OPENCODE_CONFIG_CONTENT!)).toMatchObject({
      plugin: ["custom-plugin", expect.stringMatching(/^file:/)],
      model: "xai/grok-4"
    })
    const native = join(host.dataDir, ".local", "share", "opencode")
    expect(context.env!.OPENCODE_DB).toBe(join(native, "work.db"))
    expect(await realpath(join(context.env!.XDG_DATA_HOME!, "opencode", "storage"))).toBe(
      await realpath(join(native, "storage"))
    )
    expect(
      (
        await host.shared.providers.context(account("opencode"), {
          ...base,
          env: { OPENCODE_DB: ":memory:" }
        })
      ).env!.OPENCODE_DB
    ).toBe(":memory:")
  })
  it("does not let an unchanged terminal login undo a shared account change", async () => {
    const { machine } = fleet()
    const host = await machine("selection")
    const path = join(host.dataDir, ".pi", "agent", "auth.json")
    await atomicWriteJson(path, { anthropic: credential("terminal") })
    await host.shared.providers.reconcile()
    await host.shared.providers.capture("pi", "default", "anthropic", credential("shared"), true)
    await host.shared.providers.reconcile()
    const slot = providerSlot("pi", "default", "anthropic")
    expect((await host.shared.providers.store.get(slot))?.subject).toBe("shared")
    await atomicWriteJson(path, { anthropic: { ...credential("terminal"), expires: 7_200_000 } })
    await host.shared.providers.reconcile()
    expect((await host.shared.providers.store.get(slot))?.subject).toBe("shared")
  })

  it("keeps opaque external refreshes attached to their original source without creating another grant", async () => {
    const { machine } = fleet()
    const host = await machine("opaque")
    const path = join(host.dataDir, ".pi", "agent", "auth.json")
    await atomicWriteJson(path, { anthropic: { ...credential(), access: "opaque-access" } })
    await host.shared.providers.reconcile()
    const slot = providerSlot("pi", "default", "anthropic")
    const original = (await host.shared.providers.store.get(slot))!
    await atomicWriteJson(path, {
      anthropic: {
        ...credential(),
        access: "opaque-next",
        refresh: "rotated-externally",
        expires: 7_200_000
      }
    })
    await host.shared.providers.reconcile()
    expect((await host.shared.providers.store.get(slot))?.credential.id).toBe(
      original.credential.id
    )
    expect((await host.vault.token(original.credential)).accessToken).toBe("opaque-next")
    expect((await host.vault.token(original.credential)).refreshToken).toBeUndefined()
  })

  it("clears the previous shared API key after OAuth succeeds and leaves unrelated keys alone", async () => {
    const { machine } = fleet()
    const host = await machine("replace-api")
    await run(
      host.db.mergeSyncEntries("harness-credentials", [
        {
          key: "pi-auth",
          value: JSON.stringify({
            anthropic: { type: "api_key", key: "old" },
            openai: { type: "api_key", key: "keep" }
          }),
          timestamp: { wallMs: 1000, counter: 0, deviceId: "test" }
        }
      ])
    )
    await host.shared.providers.capture("pi", "default", "anthropic", credential(), true)
    const entries = await run(host.db.getSyncEntries("harness-credentials"))
    expect(JSON.parse(entries[0]!.value as string)).toEqual({
      openai: { type: "api_key", key: "keep" }
    })
    await host.shared.providers.capture("pi", "default", "anthropic", credential(), true)
    expect(
      JSON.parse((await run(host.db.getSyncEntries("harness-credentials")))[0]!.value as string)
    ).toEqual({ openai: { type: "api_key", key: "keep" } })
  })

  it("keeps another provider usable when an externally owned token expires", async () => {
    const { machine } = fleet()
    const host = await machine("partial-expiry")
    await atomicWriteJson(join(host.dataDir, ".pi", "agent", "auth.json"), {
      anthropic: { ...credential(), expires: 0 },
      openrouter: { type: "api_key", key: "unchanged" }
    })
    await host.shared.providers.capture("pi", "default", "openai-codex", credential("working"))
    const context = await host.shared.providers.context(account("pi"), {
      id: "pi-default",
      profileKind: "default"
    })
    const auth = await json(join(context.env!.PI_CODING_AGENT_DIR!, "auth.json"))
    expect(auth.anthropic).toBeUndefined()
    expect(auth["openai-codex"]?.access).toBe(credential("working").access)
    expect(auth.openrouter?.key).toBe("unchanged")
    const base = { id: "other", profileKind: "default" as const }
    expect(await host.shared.providers.context(account("other"), base)).toBe(base)
    expect(await host.shared.providers.context(account("grok-build"), base)).toBe(base)
  })

  it("shares Pi login automatically, materializes access-only native profiles, and receives rotations on another machine", async () => {
    const { machine, sync, rotate } = fleet()
    const a = await machine("provider-a"),
      b = await machine("provider-b")
    expect(await a.shared.providers.capture("pi", "default", "anthropic", credential())).toBe(true)
    await sync(a, b)
    expect(await b.shared.providers.configured("pi", "default")).toEqual(["anthropic"])
    const first = await b.shared.providers.context(account("pi"), {
      id: "pi-default",
      profileKind: "default"
    })
    const path = first.env!.PI_CODING_AGENT_DIR!
    const auth = await json(join(path, "auth.json"))
    expect(auth.anthropic?.access).toBe(credential().access)
    expect(auth.anthropic?.refresh).toMatch(/^codevisor:/)
    expect(JSON.stringify(auth)).not.toContain("refresh-alice")
    expect((await stat(join(path, "auth.json"))).mode & 0o777).toBe(0o600)
    vi.setSystemTime(3_600_000)
    await a.shared.providers.context(account("pi"), { id: "pi-default", profileKind: "default" })
    const second = await b.shared.providers.context(account("pi"), {
      id: "pi-default",
      profileKind: "default"
    })
    expect(
      (await json(join(second.env!.PI_CODING_AGENT_DIR!, "auth.json"))).anthropic?.access
    ).toBe("rotated")
    expect(rotate).toHaveBeenCalledOnce()
    expect(await b.restart().providers.configured("pi", "default")).toEqual(["anthropic"])
  })
  it("keeps a different machine account as an override and resumes the shared identity when selected again", async () => {
    const { machine, sync } = fleet()
    const a = await machine("shared-a"),
      b = await machine("override-b")
    await a.shared.providers.capture("pi", "default", "anthropic", credential("alice"), true)
    await sync(a, b)
    await b.shared.providers.capture("pi", "default", "anthropic", credential("bob"))
    const slot = providerSlot("pi", "default", "anthropic")
    expect((await b.shared.providers.store.get(slot))?.subject).toBe("bob")
    expect((await b.shared.providers.store.get(slot, true))?.subject).toBe("alice")
    await b.shared.providers.capture("pi", "default", "anthropic", credential("alice"))
    expect(await b.shared.providers.store.local(slot)).toBeNull()
    expect((await b.shared.providers.store.get(slot))?.subject).toBe("alice")
    await b.shared.providers.capture("pi", "default", "anthropic", credential("carol"), true)
    await sync(b, a)
    expect((await a.shared.providers.store.get(slot))?.subject).toBe("carol")
  })
  it("mirrors existing native access without adopting its rotating grant or overwriting a different shared identity", async () => {
    const { machine, sync } = fleet()
    const a = await machine("native-a"),
      b = await machine("native-b")
    const path = join(a.dataDir, ".pi", "agent", "auth.json")
    await atomicWriteJson(path, {
      anthropic: credential(),
      custom: { type: "oauth", refresh: "local-only" }
    })
    await a.shared.providers.reconcile()
    await sync(a, b)
    const slot = providerSlot("pi", "default", "anthropic")
    const row = (await b.shared.providers.store.get(slot))!
    const mirrored = await b.vault.token(row.credential)
    expect(mirrored.ownership).toBe("external")
    expect(mirrored.refreshToken).toBeUndefined()
    expect(JSON.stringify(mirrored)).not.toContain("refresh-alice")
    const access = `header.${Buffer.from(JSON.stringify({ sub: "alice", next: true })).toString("base64url")}.signature`
    await atomicWriteJson(path, { anthropic: { ...credential(), access, expires: 7_200_000 } })
    await a.shared.providers.reconcile()
    // B holds a still-valid mirror; the newer one is adopted at revalidation.
    vi.setSystemTime(Date.now() + 5 * 60_000)
    expect((await b.vault.token(row.credential)).accessToken).toBe(access)
    await atomicWriteJson(join(b.dataDir, ".pi", "agent", "auth.json"), {
      anthropic: credential("bob")
    })
    await b.shared.providers.reconcile()
    expect((await b.shared.providers.store.get(slot))?.subject).toBe("bob")
    expect((await b.shared.providers.store.get(slot, true))?.subject).toBe("alice")
  })
  it("keeps local and global sign-out from rediscovering the terminal credential or falling back to it", async () => {
    const { machine, sync } = fleet()
    const a = await machine("remove-a"),
      b = await machine("remove-b")
    await atomicWriteJson(join(a.dataDir, ".pi", "agent", "auth.json"), { anthropic: credential() })
    await a.shared.providers.reconcile()
    await sync(a, b)
    expect(await a.shared.providers.remove("pi", "default", "anthropic")).toBe(true)
    await a.shared.providers.reconcile()
    expect(await a.shared.providers.configured("pi", "default")).toEqual([])
    expect(await a.shared.providers.configured("pi", "default", true)).toEqual(["anthropic"])
    const runtime = await a.shared.providers.context(account("pi"), {
      id: "pi-default",
      profileKind: "default"
    })
    expect(await json(join(runtime.env!.PI_CODING_AGENT_DIR!, "auth.json"))).not.toHaveProperty(
      "anthropic"
    )
    expect(await b.shared.providers.remove("pi", "default", "anthropic", true)).toBe(true)
    await sync(b, a)
    expect(await a.shared.providers.configured("pi", "default", true)).toEqual([])
    expect(await a.shared.providers.remove("pi", "default", "anthropic", true)).toBe(false)
  })
  it("isolates OpenCode provider state per shared profile and preserves its native refresh plugin", async () => {
    const { machine, sync } = fleet()
    const a = await machine("oc-a"),
      b = await machine("oc-b")
    for (const host of [a, b]) {
      await run(host.db.saveHarnessAccount({ ...account("opencode"), profileKind: "default" }))
      await run(
        host.db.saveHarnessAccount({
          ...account("opencode"),
          id: "shared-work",
          profileKind: "managed",
          profileKey: "shared-work"
        })
      )
    }
    await a.shared.providers.capture("opencode", "opencode-default", "openai", credential())
    await a.shared.providers.capture("opencode", "shared-work", "xai", credential("bob"), true)
    await sync(a, b)
    expect(await b.shared.providers.configured("opencode", "opencode-default")).toEqual(["openai"])
    expect(await b.shared.providers.configured("opencode", "shared-work")).toEqual(["xai"])
    const runtime = await b.shared.providers.context(account("opencode"), {
      id: "opencode-default",
      profileKind: "default"
    })
    expect(runtime.env!.OPENCODE_AUTH_CONTENT).toBe("")
    expect(JSON.parse(runtime.env!.OPENCODE_CONFIG_CONTENT!).plugin[0]).toMatch(/^file:/)
    expect(
      (await json(join(runtime.env!.XDG_DATA_HOME!, "opencode", "auth.json"))).openai?.refresh
    ).toMatch(/^codevisor:/)
    await expect(b.shared.providers.configured("opencode", "missing")).rejects.toThrow(
      "profile not found"
    )
    expect(
      await b.shared.providers.capture("opencode", "shared-work", "unknown", credential())
    ).toBe(false)
    expect(await b.shared.context("shared-work")).toBeUndefined()
    expect(await b.shared.probe("shared-work")).toBeUndefined()
  })
  it("prepares Grok's external provider command without credentials in its arguments", async () => {
    const { machine } = fleet()
    const host = await machine("grok")
    await host.shared.providers.capture("grok-build", "default", "xai", {
      auth_mode: "oidc",
      key: "access",
      refresh_token: "grok-refresh",
      expires_at: new Date(3_600_000).toISOString(),
      oidc_issuer: "https://auth.x.ai",
      oidc_client_id: "b1a00492-073a-47ea-816f-4c329264a828",
      user_id: "user"
    })
    const runtime = await host.shared.providers.context(account("grok-build"), {
      id: "grok-build-default",
      profileKind: "default"
    })
    expect(runtime.env!.GROK_AUTH_PROVIDER_COMMAND).toMatch(/^\/bin\/sh /)
    expect(runtime.env!.GROK_AUTH_PROVIDER_COMMAND).not.toContain("access")
    expect(JSON.stringify(runtime)).not.toContain("grok-refresh")
    expect(runtime.env!.GROK_HOME).toContain(host.dataDir)
    // OAuth through the provider command: no inline credential and no API
    // key may reach the process, not even as empty strings (Grok treats an
    // empty `GROK_AUTH` as supplied and then refuses `session/new`).
    expect(runtime.env).not.toHaveProperty("GROK_AUTH")
    expect(runtime.env).not.toHaveProperty("XAI_API_KEY")
    expect(runtime.unsetEnv).toEqual(expect.arrayContaining(["GROK_AUTH", "XAI_API_KEY"]))
    await host.shared.providers.remove("grok-build", "default", "xai")
    const disabled = await host.shared.providers.context(account("grok-build"), {
      id: "grok-build-default",
      profileKind: "default"
    })
    expect(disabled.env!.GROK_AUTH_PROVIDER_COMMAND).toBe("false")
  })
})

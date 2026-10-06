import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SharedTokenBundle } from "@codevisor/harness-manager"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { run } from "../test-support.js"
import { fleet } from "./shared-accounts-test-support.js"
import {
  makeOpenCode2Deps,
  seededKeyCredentials,
  seededOAuthCredential,
  type OpenCode2Deps
} from "./shared-provider-opencode2.js"

const bundle = (
  providerId: string,
  credential: Record<string, unknown> = {}
): SharedTokenBundle => ({
  harnessId: "opencode",
  providerId,
  subject: "user",
  accessToken: "access",
  expiresAt: 5_000_000,
  ownership: "managed",
  credential
})

describe("OpenCode 2 seeded credentials", () => {
  it("stores shared sign-ins the way OpenCode 2's own sign-in methods do", () => {
    expect(seededOAuthCredential(bundle("openai", { accountId: "acct" }), "cap")).toEqual({
      id: "codevisor-openai",
      integrationID: "openai",
      value: {
        type: "oauth",
        methodID: "chatgpt-browser",
        refresh: "codevisor:cap",
        access: "access",
        expires: 5_000_000,
        metadata: { accountID: "acct" }
      }
    })
    expect(
      seededOAuthCredential({ ...bundle("openai"), organizationId: "org" }, "cap")?.value
    ).toMatchObject({ metadata: { accountID: "org" } })
    expect(seededOAuthCredential(bundle("openai"), "cap")?.value).not.toHaveProperty("metadata")
    expect(seededOAuthCredential(bundle("xai"), "cap")?.value).toEqual({
      type: "oauth",
      methodID: "device",
      refresh: "codevisor:cap",
      access: "access",
      expires: 5_000_000
    })
    // Copilot keeps its long-lived GitHub token; nothing to refresh.
    expect(
      seededOAuthCredential(
        bundle("github-copilot-enterprise", { enterpriseUrl: "ghe.test" }),
        undefined
      )
    ).toMatchObject({
      id: "codevisor-github-copilot-enterprise",
      integrationID: "github-copilot",
      value: { methodID: "device", refresh: "access", metadata: { enterpriseUrl: "ghe.test" } }
    })
    expect(seededOAuthCredential(bundle("openai"), undefined)).toBeUndefined()
    expect(seededOAuthCredential(bundle("anthropic"), "cap")).toBeUndefined()
  })

  it("carries API keys over, and nothing else", () => {
    expect(
      seededKeyCredentials({
        openrouter: { type: "api", key: "sk-or" },
        empty: { type: "api", key: "" },
        known: { type: "wellknown", key: "k", token: "t" },
        broken: null
      })
    ).toEqual([
      {
        id: "codevisor-key-openrouter",
        integrationID: "openrouter",
        value: { type: "key", key: "sk-or" }
      }
    ])
  })

  it("reads OpenCode's version from the binary the environment resolves", async () => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-opencode-version-"))
    onTestFinished(() => rm(directory, { recursive: true, force: true }))
    const deps = makeOpenCode2Deps()
    expect(await deps.majorVersion({ PATH: directory })).toBeUndefined()
    await writeFile(join(directory, "opencode"), "#!/bin/sh\necho 'opencode v2.0.24'\n")
    await chmod(join(directory, "opencode"), 0o755)
    expect(await deps.majorVersion({ PATH: directory })).toBe(2)
  })
})

const oauth = (expires: number) => ({
  type: "oauth",
  access: `header.${Buffer.from(JSON.stringify({ sub: "alice" })).toString("base64url")}.signature`,
  refresh: "refresh-alice",
  expires
})

describe("OpenCode 2 shared profiles", () => {
  const account = {
    id: "opencode-default",
    harnessId: "opencode",
    profileKind: "default" as const,
    label: "Default",
    authState: "authenticated" as const,
    canLogin: true,
    canLogout: true,
    isActive: true
  }

  it("seeds an isolated database with current tokens and loads Codevisor's refresh plugin", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(1000)
    onTestFinished(() => {
      vi.useRealTimers()
    })
    const syncCredentials = vi.fn<OpenCode2Deps["syncCredentials"]>(async () => undefined)
    const f = fleet()
    const host = await f.machine("opencode2", undefined, {
      openCode2: { majorVersion: async () => 2, syncCredentials }
    })
    await run(host.db.saveHarnessAccount(account))
    await host.shared.providers.capture("opencode", "default", "openai", oauth(3_600_000))
    // Nearly expired and the vault can't refresh it: left out, so OpenCode asks to sign in.
    await host.shared.providers.capture("opencode", "default", "xai", oauth(2_000))
    f.rotate.mockRejectedValueOnce(new Error("offline"))
    const context = await host.shared.providers.context(account, {
      id: account.id,
      profileKind: "default",
      env: { OPENCODE_CONFIG_CONTENT: JSON.stringify({ plugins: ["user-plugin"], model: "x/y" }) }
    })

    const root = context.env!.XDG_DATA_HOME!.replace(/\/data$/, "")
    expect(JSON.parse(context.env!.OPENCODE_CONFIG_CONTENT!)).toEqual({
      model: "x/y",
      plugins: [
        "user-plugin",
        {
          package: join(root, "plugin"),
          options: { broker: "http://127.0.0.1:1/harness/provider-token" }
        }
      ]
    })
    expect(await readFile(join(root, "plugin", "index.mjs"), "utf8")).toContain(
      "codevisor.shared-credentials"
    )
    // No link back to the terminal's OpenCode database, and no OpenCode 1 refresh hook.
    expect(context.env).not.toHaveProperty("OPENCODE_DB")
    expect(context).not.toHaveProperty("beforeTurn")
    const [profile, seeded] = syncCredentials.mock.calls[0]!
    expect(profile).toMatchObject({ command: "opencode", cwd: host.dataDir })
    expect(seeded).toEqual([
      expect.objectContaining({
        id: "codevisor-openai",
        value: expect.objectContaining({
          methodID: "chatgpt-browser",
          refresh: expect.stringMatching(/^codevisor:/)
        })
      })
    ])
    expect(JSON.stringify(seeded)).not.toContain("refresh-alice")
  })

  it("runs without a home directory or OpenCode config of its own", async () => {
    const bareData = await mkdtemp(join(tmpdir(), "codevisor-opencode2-bare-"))
    onTestFinished(() => rm(bareData, { recursive: true, force: true }))
    const syncCredentials = vi.fn<OpenCode2Deps["syncCredentials"]>(async () => undefined)
    const host = await fleet().machine("opencode2-bare", undefined, {
      openCode2: { majorVersion: async () => 2, syncCredentials },
      // No HOME, but never the real one: credentials resolve under this XDG root.
      environment: async () => ({ XDG_DATA_HOME: bareData })
    })
    await run(host.db.saveHarnessAccount(account))
    await host.shared.providers.capture("opencode", "default", "github-copilot", oauth(3_600_000))
    const context = await host.shared.providers.context(account, {
      id: account.id,
      profileKind: "default"
    })
    expect(JSON.parse(context.env!.OPENCODE_CONFIG_CONTENT!).plugins).toHaveLength(1)
    expect(syncCredentials.mock.calls[0]?.[0].cwd).toBe(
      context.env!.XDG_DATA_HOME!.replace(/\/data$/, "")
    )
    expect(syncCredentials.mock.calls[0]?.[1]).toEqual([
      expect.objectContaining({ id: "codevisor-github-copilot", integrationID: "github-copilot" })
    ])
  })
})

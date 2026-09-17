import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import type { HarnessAuthExec } from "./harness-auth-types.js"
import type { SharedTokenBundle } from "./shared-credential-types.js"
import {
  parseClaudeOAuth,
  parseCodexOAuth,
  readNativeOAuth,
  refreshSharedOAuth,
  sharedApiKey,
  sharedOAuthIdentity
} from "./shared-oauth-providers.js"

const jwt = (value: object) =>
  `header.${Buffer.from(JSON.stringify(value)).toString("base64url")}.signature`
const claims = {
  exp: 1234,
  sub: "subject",
  email: "a@example.test",
  "https://api.openai.com/auth": {
    chatgpt_user_id: "user",
    chatgpt_account_id: "work",
    chatgpt_plan_type: "pro"
  }
}
const codex = {
  tokens: {
    access_token: jwt(claims),
    id_token: jwt(claims),
    refresh_token: "refresh",
    account_id: "work"
  }
}
const claude = {
  claudeAiOauth: {
    accessToken: "access",
    refreshToken: "refresh",
    expiresAt: 1234000,
    scopes: ["user:inference", 42]
  }
}
const settings = {
  oauthAccount: { accountUuid: "user", organizationUuid: "work", emailAddress: "a@example.test" }
}

describe("shared OAuth provider adapters", () => {
  it("deduplicates by provider subject and workspace and keeps native refresh tokens out of mirrors", () => {
    const managed = parseCodexOAuth(codex, "managed")!
    const external = parseCodexOAuth(codex, "external")!
    expect(managed.refreshToken).toBe("refresh")
    expect(external.refreshToken).toBeUndefined()
    expect(managed).toMatchObject({
      subject: "user",
      organizationId: "work",
      email: "a@example.test",
      planType: "pro",
      expiresAt: 1234000
    })
    expect(sharedOAuthIdentity(managed)).toBe(
      sharedOAuthIdentity({ ...external, email: "changed@example.test" } as SharedTokenBundle)
    )
    expect(sharedOAuthIdentity(managed)).not.toBe(
      sharedOAuthIdentity({ ...external, organizationId: "other" })
    )
    expect(sharedOAuthIdentity({ harnessId: "claude-code", subject: "user" })).toMatch(/^shared-/)
    expect(parseClaudeOAuth(claude, settings, "managed")).toMatchObject({
      refreshToken: "refresh",
      scopes: ["user:inference"],
      subject: "user"
    })
    expect(parseClaudeOAuth(claude, settings, "external")?.refreshToken).toBeUndefined()
  })

  it("rejects missing identity and malformed token metadata and recognizes static Codex keys", () => {
    for (const document of [
      undefined,
      [],
      {},
      { tokens: {} },
      { tokens: { access_token: "bad" } },
      { tokens: { access_token: jwt({ sub: "s", exp: 1 }) } }
    ]) {
      expect(parseCodexOAuth(document, "managed")).toBeUndefined()
    }
    expect(
      parseCodexOAuth(
        { tokens: { access_token: jwt({ sub: "s", exp: 1 }), account_id: "w" } },
        "managed"
      )
    ).toMatchObject({ subject: "s", organizationId: "w" })
    expect(parseCodexOAuth({ OPENAI_API_KEY: "key" }, "external")).toEqual(
      sharedApiKey("codex", "key")
    )
    expect(parseClaudeOAuth({}, settings, "managed")).toBeUndefined()
    expect(parseClaudeOAuth(claude, {}, "managed")).toBeUndefined()
    expect(
      parseClaudeOAuth(
        { claudeAiOauth: { accessToken: "a", expiresAt: 1 } },
        { oauthAccount: { accountUuid: "s" } },
        "managed"
      )
    ).toEqual({
      harnessId: "claude-code",
      subject: "s",
      accessToken: "a",
      expiresAt: 1,
      ownership: "managed"
    })
  })

  it("reads file and Keychain credentials with the correct isolated profile identity", async () => {
    const directory = await mkdtemp(join(tmpdir(), "shared-native-auth-"))
    onTestFinished(() => rm(directory, { recursive: true, force: true }))
    const exec = vi.fn<HarnessAuthExec>(async () => {
      throw new Error("missing")
    })
    const options = {
      directory,
      isDefault: true,
      ownership: "external" as const,
      env: { HOME: directory, USER: "fixture" },
      exec,
      platform: "linux"
    }
    expect(await readNativeOAuth({ ...options, harnessId: "codex" })).toBeUndefined()
    await writeFile(join(directory, "auth.json"), JSON.stringify(codex))
    expect(await readNativeOAuth({ ...options, harnessId: "codex" })).toEqual(
      parseCodexOAuth(codex, "external")
    )
    const keychain = vi.fn<HarnessAuthExec>(async () => ({
      stdout: JSON.stringify(codex),
      stderr: ""
    }))
    await readNativeOAuth({ ...options, harnessId: "codex", platform: "darwin", exec: keychain })
    expect(keychain.mock.calls[0]?.[1]).toContain("Codex Auth")
    await writeFile(join(directory, ".credentials.json"), JSON.stringify(claude))
    await writeFile(join(directory, ".claude.json"), JSON.stringify(settings))
    expect(
      await readNativeOAuth({ ...options, harnessId: "claude-code", platform: "darwin" })
    ).toEqual(parseClaudeOAuth(claude, settings, "external"))
    expect(exec.mock.calls[0]?.[1]).toContain("Claude Code-credentials")
    await readNativeOAuth({
      ...options,
      isDefault: false,
      harnessId: "claude-code",
      platform: "darwin"
    })
    expect(JSON.stringify(exec.mock.calls[1])).toContain("Claude Code-credentials-")
    expect(
      await readNativeOAuth({
        ...options,
        harnessId: "claude-code",
        env: { ANTHROPIC_API_KEY: "env-key" }
      })
    ).toEqual(sharedApiKey("claude-code", "env-key"))
    expect(
      await readNativeOAuth({ ...options, harnessId: "codex", env: { OPENAI_API_KEY: "env-key" } })
    ).toEqual(sharedApiKey("codex", "env-key"))
    const { platform: _platform, ...nativeOptions } = options
    expect(await readNativeOAuth({ ...nativeOptions, harnessId: "codex" })).toBeDefined()
    const missingDirectory = join(directory, "missing")
    const claudeKeychain = vi.fn<HarnessAuthExec>(async () => ({
      stdout: JSON.stringify(claude),
      stderr: ""
    }))
    expect(
      await readNativeOAuth({
        ...options,
        directory: missingDirectory,
        harnessId: "claude-code",
        platform: "darwin",
        env: { HOME: directory },
        exec: claudeKeychain
      })
    ).toMatchObject({ subject: "user" })
    expect(
      await readNativeOAuth({
        ...options,
        directory: missingDirectory,
        isDefault: false,
        harnessId: "claude-code",
        platform: "darwin",
        env: {},
        exec: claudeKeychain
      })
    ).toBeUndefined()
    expect(
      await readNativeOAuth({
        ...options,
        directory: missingDirectory,
        harnessId: "claude-code",
        platform: "darwin",
        env: {},
        exec: claudeKeychain
      })
    ).toBeUndefined()
    await writeFile(join(directory, "auth.json"), "broken")
    await expect(readNativeOAuth({ ...options, harnessId: "codex" })).rejects.toThrow(
      "Saved sign-in could not be read"
    )
  })

  it("uses the provider's refresh grant and preserves optional rotated fields", async () => {
    const requests: Array<{ url: string; body: Record<string, string> }> = []
    const fetcher = (async (url, options) => {
      requests.push({ url: String(url), body: JSON.parse(String(options?.body)) })
      return Response.json({
        access_token: jwt({ ...claims, exp: 5678 }),
        refresh_token: "rotated",
        id_token: jwt(claims),
        expires_in: 3600
      })
    }) as typeof fetch
    const codexResult = await refreshSharedOAuth(parseCodexOAuth(codex, "managed")!, fetcher, 1000)
    expect(codexResult.refreshToken).toBe("rotated")
    expect(codexResult.expiresAt).toBe(5678000)
    const claudeResult = await refreshSharedOAuth(
      parseClaudeOAuth(claude, settings, "managed")!,
      fetcher,
      1000
    )
    expect(claudeResult.expiresAt).toBe(3601000)
    expect(requests.map((row) => row.url)).toEqual([
      "https://auth.openai.com/oauth/token",
      "https://platform.claude.com/v1/oauth/token"
    ])
    expect(
      requests.every(
        (row) => row.body.grant_type === "refresh_token" && row.body.refresh_token === "refresh"
      )
    ).toBe(true)
    const noRotation = (async () =>
      Response.json({ access_token: jwt(claims), expires_in: 60 })) as typeof fetch
    expect(
      (await refreshSharedOAuth(parseCodexOAuth(codex, "managed")!, noRotation)).refreshToken
    ).toBe("refresh")
  })

  it("sanitizes provider errors and rejects incomplete refresh results", async () => {
    const bundle = parseClaudeOAuth(claude, settings, "managed")!
    await expect(refreshSharedOAuth({ ...bundle, ownership: "external" })).rejects.toThrow(
      "Sign in again"
    )
    for (const response of [
      new Response("SECRET", { status: 400 }),
      Response.json({}),
      Response.json({ access_token: "a", expires_in: -1 })
    ]) {
      await expect(
        refreshSharedOAuth(bundle, (async () => response) as typeof fetch)
      ).rejects.toThrow("Sign in again")
    }
    await expect(
      refreshSharedOAuth(parseCodexOAuth(codex, "managed")!, (async () =>
        Response.json({ access_token: "invalid" })) as typeof fetch)
    ).rejects.toThrow("Sign in again")
  })
})

import { mkdtemp, readFile, writeFile, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { coordinateCredential, type CredentialRecord } from "@codevisor/api"
import { afterEach, expect, it, vi } from "vitest"

import { sharedAccountVault, discoverNativeAccount } from "./shared-account-storage.js"
const execute = vi.hoisted(() =>
  vi.fn(
    (
      _cmd: string,
      _args: string[],
      _options: unknown,
      callback: (e: Error | null, out: string, err: string) => void
    ) => callback(new Error("no keychain"), "", "")
  )
)
vi.mock("node:child_process", () => ({ execFile: execute }))
const platform = Object.getOwnPropertyDescriptor(process, "platform")!
const dirs: string[] = []
afterEach(async () => {
  Object.defineProperty(process, "platform", platform)
  vi.clearAllMocks()
  vi.unstubAllGlobals()
  for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true })
})
const directory = async () => {
  const path = await mkdtemp(join(tmpdir(), "shared-storage-"))
  dirs.push(path)
  return path
}
const bundle = {
  harnessId: "claude-code" as const,
  subject: "user",
  accessToken: "old",
  refreshToken: "grant",
  expiresAt: 1,
  ownership: "managed" as const
}
it("recovers a durable encrypted receipt after a lost commit response without refreshing twice", async () => {
  const path = await directory(),
    records = new Map<string, CredentialRecord>()
  let loseCommit = true
  const coordinate = async (id: string, command: Parameters<typeof coordinateCredential>[1]) => {
    const next = coordinateCredential(records.get(id), command, "machine", 1)
    if (next.record) records.set(id, next.record)
    if (command.action === "commit" && loseCommit) {
      loseCommit = false
      throw new Error("lost response")
    }
    return next.result
  }
  const provider = vi.fn(async () =>
    Response.json({ access_token: "new", refresh_token: "rotated", expires_in: 3600 })
  )
  vi.stubGlobal("fetch", provider)
  const vault = sharedAccountVault(path, coordinate)
  const reference = await vault.create(bundle)
  await expect(vault.token(reference)).rejects.toThrow("lost response")
  const receipt = join(path, "shared-credentials", `${reference.id}.receipt.json`)
  expect((await stat(receipt)).mode & 0o777).toBe(0o600)
  expect(await readFile(receipt, "utf8")).not.toContain("rotated")
  expect((await sharedAccountVault(path, coordinate).token(reference)).accessToken).toBe("new")
  expect(provider).toHaveBeenCalledOnce()
  await expect(stat(receipt)).rejects.toMatchObject({ code: "ENOENT" })
  await writeFile(receipt, "{")
  await expect(sharedAccountVault(path, coordinate).token(reference)).rejects.toThrow(
    "when connected"
  )
})
it("uses the protected local coordinator and discovers API keys with the supplied environment", async () => {
  const path = await directory()
  const vault = sharedAccountVault(path)
  const reference = await vault.create({ ...bundle, expiresAt: Number.MAX_SAFE_INTEGER })
  expect((await vault.token(reference)).accessToken).toBe("old")
  expect(
    await discoverNativeAccount("codex", path, true, false, { OPENAI_API_KEY: "test-key" })
  ).toMatchObject({ authMethod: "apiKey", accessToken: "test-key" })
  expect(execute).not.toHaveBeenCalled()
})
it.each(["darwin", "linux"])(
  "discovers file credentials with unavailable Keychain on %s",
  async (host) => {
    Object.defineProperty(process, "platform", { value: host, configurable: true })
    const path = await directory()
    await writeFile(
      join(path, ".credentials.json"),
      JSON.stringify({
        claudeAiOauth: { accessToken: "native", refreshToken: "native-grant", expiresAt: 100000 }
      })
    )
    await writeFile(
      join(path, ".claude.json"),
      JSON.stringify({ oauthAccount: { accountUuid: "user", organizationUuid: "org" } })
    )
    expect(
      await discoverNativeAccount("claude-code", path, false, true, { HOME: path, USER: "fixture" })
    ).toMatchObject({ ownership: "managed", refreshToken: "native-grant" })
    if (host === "darwin") {
      expect(execute).toHaveBeenCalledExactlyOnceWith(
        "/usr/bin/security",
        [
          "find-generic-password",
          "-s",
          expect.stringMatching(/^Claude Code-credentials-/),
          "-a",
          "fixture",
          "-w"
        ],
        expect.objectContaining({ encoding: "utf8" }),
        expect.any(Function)
      )
    } else {
      expect(execute).not.toHaveBeenCalled()
    }
  }
)

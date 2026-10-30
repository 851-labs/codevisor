import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import {
  readClaudeMachineLogin,
  signOutClaudeMachineLogin,
  type ClaudeMachineLoginOptions
} from "./claude-machine-login.js"
import type { HarnessAuthExec } from "./harness-auth-types.js"

const service = "Claude Code-credentials-devtest"
const login = {
  accessToken: "machine-access",
  refreshToken: "machine-refresh",
  expiresAt: 10_000_000,
  scopes: ["user:inference"]
}
const mcpLogins = { mcpOAuth: { server: { accessToken: "mcp-access" } } }

const configDirectory = async () => {
  const directory = await mkdtemp(join(tmpdir(), "claude-machine-login-"))
  onTestFinished(() => rm(directory, { force: true, recursive: true }))
  return directory
}

const securityExit = (code: number) => Object.assign(new Error("security failed"), { code })

const fakeKeychain = (initial: unknown, { ignoresWrites = false } = {}) => {
  let item = initial === undefined ? undefined : JSON.stringify(initial)
  const exec = vi.fn<HarnessAuthExec>(async (_command, args, options) => {
    const [action] = args
    if (action === "-i") {
      const hex = /-X "([0-9a-f]+)"/.exec(options.input ?? "")?.[1]
      if (!ignoresWrites) item = Buffer.from(hex ?? "", "hex").toString("utf8")
      return { stdout: "", stderr: "" }
    }
    if (item === undefined) throw securityExit(44)
    if (action === "delete-generic-password") item = undefined
    return { stdout: item ?? "", stderr: "" }
  })
  return { exec, item: () => (item === undefined ? undefined : JSON.parse(item)) }
}

const optionsFor = (
  directory: string,
  exec: HarnessAuthExec,
  platform = "darwin"
): ClaudeMachineLoginOptions => ({
  location: { directory, keychainService: service, isDefault: false },
  env: { USER: "fixture" },
  exec,
  platform
})

describe("this machine's Claude Code login", () => {
  it("reads the full login, refresh token and scopes included, from the injected Keychain item", async () => {
    const directory = await configDirectory()
    await writeFile(
      join(directory, ".claude.json"),
      JSON.stringify({ oauthAccount: { accountUuid: "alice", emailAddress: "alice@example.test" } })
    )
    const keychain = fakeKeychain({ claudeAiOauth: login })

    const bundle = await readClaudeMachineLogin(optionsFor(directory, keychain.exec))

    expect(bundle).toMatchObject({ ...login, subject: "alice", ownership: "managed" })
    expect(keychain.exec.mock.calls.every(([, args]) => args.includes(service))).toBe(true)
  })

  it.each([
    ["deletes the Keychain item that held only the login", {}, undefined],
    ["keeps Claude Code's other saved sign-ins in the Keychain item", mcpLogins, mcpLogins]
  ])("%s", async (_case, others, remaining) => {
    const keychain = fakeKeychain({ claudeAiOauth: login, ...others })

    await signOutClaudeMachineLogin(optionsFor(await configDirectory(), keychain.exec))

    expect(keychain.item()).toEqual(remaining)
    expect(JSON.stringify(keychain.exec.mock.calls.map(([, args]) => args))).not.toMatch(
      /machine-refresh|mcp-access|[0-9a-f]{40}/
    )
  })

  it.each([
    ["removes a credentials file that held only the login", {}, undefined],
    ["keeps Claude Code's other saved sign-ins in the credentials file", mcpLogins, mcpLogins]
  ])("%s", async (_case, others, remaining) => {
    const directory = await configDirectory()
    const path = join(directory, ".credentials.json")
    await writeFile(path, JSON.stringify({ claudeAiOauth: login, ...others }))
    const exec = vi.fn<HarnessAuthExec>()

    await signOutClaudeMachineLogin(optionsFor(directory, exec, "linux"))

    const left = await readFile(path, "utf8").then(JSON.parse, () => undefined)
    expect(left).toEqual(remaining)
    expect(exec).not.toHaveBeenCalled()
  })

  it.each<[string, (directory: string) => Promise<HarnessAuthExec>, object]>([
    [
      "the Keychain still holds the login afterwards",
      async () =>
        fakeKeychain({ claudeAiOauth: login, ...mcpLogins }, { ignoresWrites: true }).exec,
      { message: "Claude Code's login is still in the Keychain" }
    ],
    [
      "the Keychain cannot be read",
      async () =>
        vi.fn<HarnessAuthExec>(async () => {
          throw securityExit(51)
        }),
      { code: 51 }
    ],
    [
      "the credentials file cannot be read",
      async (directory) => {
        await mkdir(join(directory, ".credentials.json"))
        return vi.fn<HarnessAuthExec>()
      },
      { code: "EISDIR" }
    ]
  ])("refuses to report success when %s", async (_case, arrange, failure) => {
    const directory = await configDirectory()
    const exec = await arrange(directory)

    await expect(signOutClaudeMachineLogin(optionsFor(directory, exec))).rejects.toMatchObject(
      failure
    )
  })

  it.each([
    ["without a Claude login", JSON.stringify(mcpLogins)],
    ["it cannot parse", "not json"]
  ])("leaves a Keychain item %s alone", async (_case, contents) => {
    const directory = await configDirectory()
    const exec = vi.fn<HarnessAuthExec>(async () => ({ stdout: contents, stderr: "" }))

    await signOutClaudeMachineLogin(optionsFor(directory, exec))

    expect(exec).toHaveBeenCalledOnce()
    await expect(stat(join(directory, ".credentials.json"))).rejects.toThrow()
  })
})

import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { OpenCodeMigration } from "@codevisor/adapter-opencode"
import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeOpenCodeSetup, openCodeAccountContexts } from "./opencode-setup.js"

const directories: Array<string> = []
afterEach(async () => {
  await Promise.all(directories.splice(0).map((path) => rm(path, { force: true, recursive: true })))
})

const env = { HOME: "/home/me", PATH: "/bin", OPENCODE_AUTH_CONTENT: "{}" }
const opencode2 = {
  locate: () => "/home/me/.opencode/bin/opencode",
  majorVersion: async () => 2
}

/// A migration per data directory: pending for `pendingFor`, failing to
/// start on "/broken".
const migrations = (pendingFor: ReadonlyArray<string | undefined>) => {
  const finished: Array<string> = []
  const migration = vi.fn(
    async (command: string, chat: NodeJS.ProcessEnv): Promise<OpenCodeMigration | undefined> => {
      expect(command).toBe("/home/me/.opencode/bin/opencode")
      if (chat.XDG_DATA_HOME === "/broken") throw new Error("OpenCode server exited")
      if (!pendingFor.includes(chat.XDG_DATA_HOME)) return undefined
      return {
        finish: async () => {
          finished.push(chat.XDG_DATA_HOME ?? "own")
        }
      }
    }
  )
  return { finished, migration }
}

const account = (id: string, data?: string): HarnessAccountContext => ({
  id,
  profileKind: data === undefined ? "default" : "managed",
  ...(data === undefined ? {} : { env: { XDG_DATA_HOME: data } }),
  unsetEnv: ["OPENCODE_AUTH_CONTENT"]
})

describe("OpenCode setup", () => {
  it("has none without OpenCode 2", async () => {
    const { migration } = migrations([])
    expect(await makeOpenCodeSetup({ locate: () => undefined, migration })(env)).toBeUndefined()
    for (const major of [1, undefined]) {
      const setup = makeOpenCodeSetup({
        locate: () => "/opt/homebrew/bin/opencode",
        majorVersion: async () => major,
        migration
      })
      expect(await setup(env)).toBeUndefined()
    }
    expect(migration).not.toHaveBeenCalled()
    // By default, only an installed OpenCode is run.
    const directory = await mkdtemp(join(tmpdir(), "codevisor-opencode-setup-"))
    directories.push(directory)
    expect(await makeOpenCodeSetup()({ HOME: directory, PATH: directory })).toBeUndefined()
  })

  it("migrates the data each account's chats use, once per data directory", async () => {
    const { finished, migration } = migrations(["/profiles/work", undefined])
    const setup = makeOpenCodeSetup({
      ...opencode2,
      accounts: async () => [
        account("default"),
        account("work", "/profiles/work"),
        account("work-again", "/profiles/work"),
        // An account that hides nothing from OpenCode.
        { id: "done", profileKind: "managed", env: { XDG_DATA_HOME: "/profiles/done" } }
      ],
      migration
    })
    const pending = await setup(env)
    expect(migration.mock.calls.map(([, chat]) => chat)).toEqual([
      { HOME: "/home/me", PATH: "/bin" },
      { HOME: "/home/me", PATH: "/bin", XDG_DATA_HOME: "/profiles/work" },
      { ...env, XDG_DATA_HOME: "/profiles/done" }
    ])
    await pending!.finish()
    expect(finished.toSorted()).toEqual(["/profiles/work", "own"])
  })

  it("uses the user's own environment without accounts", async () => {
    const { migration } = migrations([undefined])
    const noAccounts = [
      undefined,
      async () => [],
      async () => Promise.reject(new Error("database closed"))
    ]
    for (const accounts of noAccounts) {
      migration.mockClear()
      const setup = makeOpenCodeSetup({
        ...opencode2,
        migration,
        ...(accounts === undefined ? {} : { accounts })
      })
      expect(await setup(env)).toBeDefined()
      expect(migration.mock.calls.map(([, chat]) => chat)).toEqual([env])
    }
  })

  it("leaves an account that can't be checked to its chats, unless none can be", async () => {
    const { migration } = migrations([])
    const one = makeOpenCodeSetup({
      ...opencode2,
      accounts: async () => [account("default"), account("broken", "/broken")],
      migration
    })
    expect(await one(env)).toBeUndefined()
    const all = makeOpenCodeSetup({
      ...opencode2,
      accounts: async () => [account("broken", "/broken")],
      migration
    })
    await expect(all(env)).rejects.toThrow("OpenCode server exited")
  })

  it("prepares every OpenCode account's chat environment it can", async () => {
    const auth = {
      accounts: vi.fn(async () => [{ id: "default" }, { id: "broken" }, { id: "work" }]),
      accountContext: vi.fn(async (id: string) => {
        if (id === "broken") throw new Error("no credentials")
        return account(id)
      })
    }
    const contexts = await openCodeAccountContexts(auth as never)()
    expect(auth.accounts).toHaveBeenCalledWith("opencode")
    expect(contexts.map((context) => context.id)).toEqual(["default", "work"])
  })
})

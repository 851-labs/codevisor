import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeHarnessAuthManager } from "./harness-auth.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  vi.useRealTimers()
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("Cursor authentication probing", () => {
  const setup = async (
    execute: NonNullable<Parameters<typeof makeHarnessAuthManager>[0]["execFile"]>
  ) => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-cursor-auth-"))
    directories.push(directory)
    const binary = join(directory, "cursor-agent")
    writeFileSync(binary, "#!/bin/sh\nexit 0\n")
    chmodSync(binary, 0o700)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const account = await run(
      db.saveHarnessAccount({
        id: "cursor-account",
        harnessId: "cursor",
        profileKind: "default",
        label: "Existing Cursor account",
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )
    const manager = makeHarnessAuthManager({
      agents: {} as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      execFile: execute,
      resolveEnv: () => Promise.resolve({ HOME: directory, PATH: directory })
    })
    return { account, directory, manager }
  }

  it("replaces the placeholder label with the signed-in identity and allows signing out", async () => {
    const execute = vi.fn(async () => ({
      stdout: JSON.stringify({
        status: "authenticated",
        isAuthenticated: true,
        userInfo: { email: "person@example.com", userId: 1, firstName: "Person" }
      }),
      stderr: ""
    }))
    const { account, directory, manager } = await setup(execute)

    await expect(manager.probeAccount(account.id, true)).resolves.toMatchObject({
      authState: "authenticated",
      email: "person@example.com",
      label: "person@example.com",
      canLogin: true,
      canLogout: true
    })
    expect(execute).toHaveBeenCalledWith(
      join(directory, "cursor-agent"),
      ["status", "--format", "json"],
      expect.objectContaining({ cwd: directory })
    )
  })

  it("reports a signed-out CLI as unauthenticated without offering sign-out", async () => {
    const execute = vi.fn(async () => ({
      stdout: JSON.stringify({ status: "unauthenticated", isAuthenticated: false }),
      stderr: ""
    }))
    const { account, manager } = await setup(execute)

    await expect(manager.probeAccount(account.id, true)).resolves.toMatchObject({
      authState: "unauthenticated",
      canLogin: true,
      canLogout: false
    })
  })

  it("reads a signed-out payload off a non-zero exit rather than calling it an error", async () => {
    const execute = vi.fn(async () => {
      throw Object.assign(new Error("exit 1"), {
        code: 1,
        stdout: JSON.stringify({ isAuthenticated: false }),
        stderr: ""
      })
    })
    const { account, manager } = await setup(execute)

    await expect(manager.probeAccount(account.id, true)).resolves.toMatchObject({
      authState: "unauthenticated",
      canLogout: false
    })
  })

  it("reports an execution failure as an error instead of signed out", async () => {
    const execute = vi.fn(async () => {
      throw Object.assign(new Error("spawn failed"), {
        code: 127,
        stdout: "",
        stderr: "ENOENT"
      })
    })
    const { account, manager } = await setup(execute)

    await expect(manager.probeAccount(account.id, true)).resolves.toMatchObject({
      authState: "error",
      canLogout: false,
      detail: "Unable to check Cursor sign-in (cursor-agent exited with status 127)"
    })
  })

  it("signs out through the CLI and re-probes", async () => {
    const execute = vi.fn(async (_command: string, args: ReadonlyArray<string>) =>
      args[0] === "logout"
        ? { stdout: "", stderr: "" }
        : { stdout: JSON.stringify({ isAuthenticated: false }), stderr: "" }
    )
    const { account, directory, manager } = await setup(execute)

    await expect(manager.logout(account.id)).resolves.toMatchObject({
      authState: "unauthenticated",
      canLogout: false
    })
    expect(execute).toHaveBeenCalledWith(
      join(directory, "cursor-agent"),
      ["logout"],
      expect.objectContaining({ cwd: directory })
    )
  })
})

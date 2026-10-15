import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { makeHarnessAuthManager } from "./harness-auth.js"
import { fakeAgentRuntime, fakeTerminalManager } from "./harness-lifecycle-test-support.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

describe("Claude account selection", () => {
  it("rebinds chats whose previous account still authenticates", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-claude-activate-"))
    directories.push(directory)
    const binary = join(directory, "claude")
    writeFileSync(binary, "#!/bin/sh\nexit 0\n")
    chmodSync(binary, 0o700)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const project = await run(
      db.createProject({ name: "Claude switch", folderPath: join(directory, "project") })
    )
    const saveAccount = (id: string) =>
      run(
        db.saveHarnessAccount({
          id,
          harnessId: "claude-code",
          profileKind: "managed",
          profileKey: id,
          label: id,
          authState: "authenticated",
          canLogin: true,
          canLogout: true
        })
      )
    const exhausted = await saveAccount("claude-exhausted")
    const selected = await saveAccount("claude-selected")
    const exhaustedProfile = join(directory, "harness-profiles", "claude-code", exhausted.id)
    const selectedProfile = join(directory, "harness-profiles", "claude-code", selected.id)
    const nativeProject = "-tmp-project"
    const nativeSession = "11111111-1111-4111-8111-111111111111.jsonl"
    mkdirSync(join(exhaustedProfile, "projects", nativeProject), { recursive: true })
    writeFileSync(join(exhaustedProfile, "projects", nativeProject, nativeSession), "history\n")
    const session = await run(
      db.createSession({
        projectId: project.id,
        harnessId: "claude-code",
        harnessAccountId: exhausted.id
      })
    )
    const manager = makeHarnessAuthManager({
      agents: fakeAgentRuntime(),
      dataDir: directory,
      db,
      terminal: fakeTerminalManager(),
      execFile: async () => ({
        stdout: JSON.stringify({ loggedIn: true, authMethod: "claude.ai" }),
        stderr: ""
      }),
      resolveEnv: () => Promise.resolve({ HOME: directory, PATH: directory })
    })
    await expect(manager.accountContext(selected.id)).resolves.toMatchObject({
      id: selected.id,
      env: { CLAUDE_CONFIG_DIR: selectedProfile }
    })
    const sharedProjects = realpathSync(join(directory, ".claude", "projects"))
    expect(realpathSync(join(exhaustedProfile, "projects"))).toBe(sharedProjects)
    expect(realpathSync(join(selectedProfile, "projects"))).toBe(sharedProjects)
    expect(
      readFileSync(join(directory, ".claude", "projects", nativeProject, nativeSession), "utf8")
    ).toBe("history\n")

    await manager.activateAccount("claude-code", selected.id)

    expect((await run(db.getSessionSummary(session.id))).harnessAccountId).toBe(selected.id)
  })
})

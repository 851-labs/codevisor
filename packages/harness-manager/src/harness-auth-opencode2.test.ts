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
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

describe("OpenCode 2 providers", () => {
  it("lists a profile's providers from OpenCode 2's own catalog, keeping shared sign-ins", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-opencode2-providers-"))
    directories.push(directory)
    const binary = join(directory, "opencode")
    writeFileSync(binary, "#!/bin/sh\nexit 0\n")
    chmodSync(binary, 0o700)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    await run(
      db.saveHarnessAccount({
        id: "opencode-default",
        harnessId: "opencode",
        profileKind: "default",
        label: "Default",
        authState: "authenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const providers = vi.fn(async () => [
      { id: "openai", name: "OpenAI", methods: [] },
      { id: "anthropic", name: "Anthropic", methods: [] }
    ])
    const manager = makeHarnessAuthManager({
      agents: {} as AgentRuntimeService,
      dataDir: directory,
      db,
      terminal: {} as TerminalManagerService,
      resolveEnv: () => Promise.resolve({ HOME: directory, PATH: directory }),
      openCode: { majorVersion: async () => 2, accounts: { providers } },
      sharedProviders: () =>
        ({
          configured: async () => ["openai"],
          disabled: async () => []
        }) as never
    })

    expect(await manager.openCodeProviders!("opencode-default")).toEqual([
      { id: "openai", name: "OpenAI", methods: [], credentialType: "oauth" },
      { id: "anthropic", name: "Anthropic", methods: [] }
    ])
    expect(providers).toHaveBeenCalledWith(expect.objectContaining({ command: binary }))
  })
})

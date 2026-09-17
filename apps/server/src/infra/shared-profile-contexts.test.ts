import { mkdir, readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { Effect } from "effect"
import { afterEach, expect, it, vi } from "vitest"

import { fleet, native } from "./shared-accounts-test-support.js"
const home = vi.hoisted(() => ({ path: "" }))
vi.mock("node:os", async (original) => ({
  ...(await original<typeof import("node:os")>()),
  homedir: () => home.path
}))
afterEach(() => vi.useRealTimers())
it.each(["configured", "home", "fallback", "managed"])(
  "preserves existing native Codex threads with %s profile discovery",
  async (mode) => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    let env: NodeJS.ProcessEnv = {}
    const f = fleet(),
      m = await f.machine("a", native("alice"), { environment: async () => env })
    home.path = m.dataDir
    env =
      mode === "configured"
        ? { CODEX_HOME: join(m.dataDir, "custom") }
        : mode === "home"
          ? { HOME: m.dataDir }
          : {}
    const path =
      mode === "managed"
        ? join(m.dataDir, "harness-profiles", "codex", "original")
        : (env.CODEX_HOME ?? join(m.dataDir, ".codex"))
    await mkdir(join(path, "sessions"), { recursive: true })
    await writeFile(join(path, "sessions", "existing.jsonl"), "existing transcript")
    const account = await Effect.runPromise(
      m.db.saveHarnessAccount({
        id: "original",
        harnessId: "codex",
        profileKind: mode === "managed" ? "managed" : "default",
        label: "Native",
        authState: "authenticated",
        canLogin: true,
        canLogout: true
      })
    )
    const project = await Effect.runPromise(
      m.db.createProject({ name: "Existing", folderPath: m.dataDir })
    )
    const session = await Effect.runPromise(
      m.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        harnessAccountId: account.id,
        agentSessionId: "existing-thread"
      })
    )
    await m.shared.reconcile()
    expect((await Effect.runPromise(m.db.getSessionSummary(session.id)))?.harnessAccountId).toBe(
      account.id
    )
    const context = await m.shared.context(account.id)
    expect(context?.env?.CODEX_HOME).toBe(path)
    expect(
      await readFile(join(context!.env!.CODEX_HOME!, "sessions", "existing.jsonl"), "utf8")
    ).toBe("existing transcript")
    expect(context?.oauth).toBeDefined()
    if (mode === "managed") {
      await Effect.runPromise(m.db.deleteSession(session.id))
      await Effect.runPromise(m.db.removeHarnessAccount(account.id))
      expect((await m.shared.context(account.id))?.profilePath).toContain(
        "harness-profiles/codex/shared-"
      )
    }
  }
)

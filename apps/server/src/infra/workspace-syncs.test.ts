import { execFileSync } from "node:child_process"
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { tempDirs } from "../test-support.js"
import { makeMirrorStore, type MirrorStore } from "./mirror-store.js"
import { makeWorkspaceSyncs, type MirrorTransport } from "./workspace-syncs.js"

const HOUR_MS = 60 * 60 * 1000

const tempDir = (prefix: string): string => {
  const directory = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(directory)
  return directory
}

const localTransport = (mirrors: MirrorStore): MirrorTransport => ({
  prepare: (_machine, mirrorId, name) => mirrors.prepare(mirrorId, name, "server-a"),
  write: (_machine, mirrorId, offset, data) => mirrors.write(mirrorId, offset, data),
  apply: (_machine, mirrorId, commit, head) => mirrors.apply(mirrorId, commit, head),
  remove: (_machine, mirrorId) => mirrors.remove(mirrorId)
})

const offline = async (): Promise<never> => {
  throw new Error("MacBook is offline")
}

const offlineTransport = (): MirrorTransport => ({
  prepare: offline,
  write: offline,
  apply: offline,
  remove: offline
})

const project = (): string => {
  const root = tempDir("codevisor-sync-source-")
  mkdirSync(join(root, "src"))
  mkdirSync(join(root, "node_modules", "dep"), { recursive: true })
  writeFileSync(join(root, ".gitignore"), "node_modules/\n")
  writeFileSync(join(root, "src", "app.ts"), "export const answer = 41\n")
  writeFileSync(join(root, "src", "keep.ts"), "export const kept = true\n")
  writeFileSync(join(root, "node_modules", "dep", "index.js"), "ignored\n")
  return root
}

const syncsWith = (transport: MirrorTransport, directory = tempDir("codevisor-sync-state-")) => {
  const syncs = makeWorkspaceSyncs({ directory, transport, intervalMs: HOUR_MS, retryMs: HOUR_MS })
  onTestFinished(() => syncs.close())
  return { syncs, directory }
}

const macbook = { id: "machine-mbp", name: "MacBook" }

const gitIn = (cwd: string, ...args: string[]): string =>
  execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Dev",
      GIT_AUTHOR_EMAIL: "dev@example.com",
      GIT_COMMITTER_NAME: "Dev",
      GIT_COMMITTER_EMAIL: "dev@example.com"
    }
  }).trim()

const gitProject = (): string => {
  const root = project()
  gitIn(root, "init", "--quiet", "--initial-branch", "main")
  gitIn(root, "add", "--all")
  gitIn(root, "commit", "--quiet", "-m", "First")
  writeFileSync(join(root, "src", "app.ts"), "export const answer = 42\n")
  gitIn(root, "commit", "--quiet", "-am", "Second")
  gitIn(root, "switch", "--quiet", "-c", "feature")
  writeFileSync(join(root, "src", "app.ts"), "uncommitted\n")
  return root
}

describe("workspace syncs", () => {
  it("copies the workspace, then sends only what changed", async () => {
    const root = project()
    const mirrors = makeMirrorStore(tempDir("codevisor-mirrors-"))
    const { syncs } = syncsWith(localTransport(mirrors))
    await syncs.start({ id: "ws-1", name: "My Site", root }, macbook)

    const first = await syncs.wait("ws-1", macbook.id, HOUR_MS)
    const path = first?.path ?? ""
    expect(first).toMatchObject({ state: "synced", pendingChanges: false, timedOut: false })
    expect(path).toMatch(/My-Site-/)
    expect(readFileSync(join(path, "src", "app.ts"), "utf8")).toBe("export const answer = 41\n")
    expect(existsSync(join(path, "node_modules"))).toBe(false)

    const keptAt = statSync(join(path, "src", "keep.ts")).mtimeMs
    writeFileSync(join(path, "build.log"), "made on the mac")
    writeFileSync(join(root, "src", "app.ts"), "export const answer = 42\n")
    writeFileSync(join(root, "src", "new.ts"), "export {}\n")
    expect((await syncs.status("ws-1", macbook.id))?.pendingChanges).toBe(true)

    const second = await syncs.wait("ws-1", macbook.id, HOUR_MS)
    expect(second?.lastSync?.files).toBe(2)
    expect(readFileSync(join(path, "src", "app.ts"), "utf8")).toBe("export const answer = 42\n")
    expect(existsSync(join(path, "src", "new.ts"))).toBe(true)
    expect(statSync(join(path, "src", "keep.ts")).mtimeMs).toBe(keptAt)
    expect(readFileSync(join(path, "build.log"), "utf8")).toBe("made on the mac")

    rmSync(join(root, "src", "new.ts"))
    await syncs.wait("ws-1", macbook.id, HOUR_MS)
    expect(existsSync(join(path, "src", "new.ts"))).toBe(false)
  })

  it("keeps syncing after a restart and deletes the copy when stopped", async () => {
    const root = project()
    const mirrors = makeMirrorStore(tempDir("codevisor-mirrors-"))
    const first = syncsWith(localTransport(mirrors))
    const started = await first.syncs.start({ id: "ws-1", name: "site", root }, macbook)
    expect(started.state).toBe("syncing")
    const path = (await first.syncs.wait("ws-1", macbook.id, HOUR_MS))?.path ?? ""
    first.syncs.close()

    writeFileSync(join(root, "src", "app.ts"), "after restart\n")
    const second = syncsWith(localTransport(mirrors), first.directory)
    expect(await second.syncs.list("ws-1")).toHaveLength(1)
    const resumed = await second.syncs.wait("ws-1", macbook.id, HOUR_MS)
    expect(resumed?.lastSync?.files).toBe(1)
    expect(readFileSync(join(path, "src", "app.ts"), "utf8")).toBe("after restart\n")

    await second.syncs.stopAll("ws-1")
    expect(existsSync(path)).toBe(false)
    expect(await second.syncs.list("ws-1")).toEqual([])
    expect(await second.syncs.stop("ws-1", macbook.id)).toBe(false)
  })

  it("reports a failing machine and deletes the copy once it is back", async () => {
    const root = project()
    const unreachable = syncsWith(offlineTransport())
    await unreachable.syncs.start({ id: "ws-1", name: "site", root }, macbook)

    const failed = await unreachable.syncs.wait("ws-1", macbook.id, HOUR_MS)
    expect(failed).toMatchObject({ state: "failed", error: "MacBook is offline" })
    await unreachable.syncs.stop("ws-1", macbook.id)
    unreachable.syncs.close()

    const removed: string[] = []
    const mirrors = makeMirrorStore(tempDir("codevisor-mirrors-"))
    const back = {
      ...localTransport(mirrors),
      remove: async (_machine: string, mirrorId: string) => {
        removed.push(mirrorId)
      }
    }
    const online = syncsWith(back, unreachable.directory)
    await online.syncs.list("ws-1")
    expect(removed).toHaveLength(1)
  })
  it("makes the copy a git checkout at the same commit and branch, without history", async () => {
    const root = gitProject()
    const mirrors = makeMirrorStore(tempDir("codevisor-mirrors-"))
    const { syncs } = syncsWith(localTransport(mirrors))
    await syncs.start({ id: "ws-1", name: "site", root }, macbook)

    const path = (await syncs.wait("ws-1", macbook.id, HOUR_MS))?.path ?? ""
    expect(gitIn(path, "rev-parse", "HEAD")).toBe(gitIn(root, "rev-parse", "HEAD"))
    expect(gitIn(path, "branch", "--show-current")).toBe("feature")
    expect(gitIn(path, "log", "--format=%s")).toBe("Second")
    expect(gitIn(path, "diff", "--cached", "--name-only")).toBe("src/app.ts")
    expect(gitIn(path, "hash-object", "src/app.ts")).toBe(gitIn(root, "hash-object", "src/app.ts"))

    gitIn(root, "commit", "--quiet", "-am", "Third")
    const moved = await syncs.wait("ws-1", macbook.id, HOUR_MS)
    expect(moved?.lastSync?.files).toBe(0)
    expect(gitIn(path, "rev-parse", "HEAD")).toBe(gitIn(root, "rev-parse", "HEAD"))
    expect(gitIn(path, "status", "--porcelain")).toBe("")
    expect(gitIn(path, "fsck", "--no-progress")).toBe("")
  })
})

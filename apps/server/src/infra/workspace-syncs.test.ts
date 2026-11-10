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
  apply: (_machine, mirrorId, commit) => mirrors.apply(mirrorId, commit),
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
})

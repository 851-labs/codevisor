import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  claimInstanceRoot,
  instanceWorktreesRoot,
  pruneOrphanInstanceRoots
} from "./dev-instance-roots.ts"

const roots: Array<string> = []
const scratch = async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-instance-roots-test-"))
  roots.push(root)
  return root
}
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })))
})

describe("instanceWorktreesRoot", () => {
  it("puts a worktree's agent folders outside the repo, one place per worktree", async () => {
    const instances = await scratch()

    const cayenne = instanceWorktreesRoot("/repo/worktrees/cayenne", instances)

    expect(dirname(dirname(cayenne))).toBe(instances)
    expect(instanceWorktreesRoot("/repo/worktrees/cayenne", instances)).toBe(cayenne)
    expect(instanceWorktreesRoot("/repo/worktrees/quark", instances)).not.toBe(cayenne)
  })

  it("keeps using the folder inside tmp while it still holds agent folders", async () => {
    const repo = await scratch()
    const legacy = join(repo, "tmp", "codevisor")
    await mkdir(legacy, { recursive: true })
    const empty = instanceWorktreesRoot(repo, await scratch())
    await mkdir(join(legacy, "bots.noindex"))

    expect(empty).not.toBe(legacy)
    expect(instanceWorktreesRoot(repo, await scratch())).toBe(legacy)
  })
})

describe("pruneOrphanInstanceRoots", () => {
  it("removes the folders of worktrees that are gone and leaves the rest", async () => {
    const instances = await scratch()
    const live = await scratch()
    const liveRoot = instanceWorktreesRoot(live, instances)
    const goneRoot = instanceWorktreesRoot("/repo/worktrees/deleted", instances)
    await claimInstanceRoot(live, liveRoot, instances)
    await claimInstanceRoot("/repo/worktrees/deleted", goneRoot, instances)
    await mkdir(join(instances, "unclaimed"))
    const removed: Array<string> = []

    const orphans = await pruneOrphanInstanceRoots(instances, (path) => removed.push(path))

    expect(orphans).toEqual([dirname(goneRoot)])
    expect(removed).toEqual([dirname(goneRoot)])
    expect(await readFile(join(dirname(liveRoot), "repo-root"), "utf8")).toBe(live)
  })

  it("claims nothing for a root the environment moved elsewhere", async () => {
    const instances = await scratch()
    const elsewhere = join(await scratch(), "agent-folders")
    await writeFile(join(instances, "keep"), "")

    await claimInstanceRoot("/repo", elsewhere, instances)

    expect(await pruneOrphanInstanceRoots(instances, () => undefined)).toEqual([])
  })
})

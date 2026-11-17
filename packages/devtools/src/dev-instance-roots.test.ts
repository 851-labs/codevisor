import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  claimedInstances,
  claimInstance,
  instanceHash,
  instanceWorktreesRoot,
  worktreeIsGone
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

describe("claimedInstances", () => {
  it("lists every claimed worktree and skips folders nobody claimed", async () => {
    const instances = await scratch()
    await claimInstance("/repo/worktrees/cayenne", instances)
    await mkdir(join(instances, "unclaimed"))

    expect(await claimedInstances(instances)).toEqual([
      {
        hash: instanceHash("/repo/worktrees/cayenne"),
        root: join(instances, instanceHash("/repo/worktrees/cayenne")),
        repoRoot: "/repo/worktrees/cayenne"
      }
    ])
  })

  it("ignores a claim that names a different worktree than its folder", async () => {
    const instances = await scratch()
    await claimInstance("/repo/worktrees/cayenne", instances)
    await writeFile(
      join(instances, instanceHash("/repo/worktrees/cayenne"), "repo-root"),
      "/repo/worktrees/quark"
    )

    expect(await claimedInstances(instances)).toEqual([])
  })
})

describe("worktreeIsGone", () => {
  it("still sees a worktree mid-checkout, when only its git link is there", async () => {
    const repo = await scratch()
    await writeFile(join(repo, ".git"), "gitdir: elsewhere")

    expect(await worktreeIsGone(repo)).toBe(false)
  })

  it("treats a folder that only holds recreated build output as gone", async () => {
    const repo = await scratch()
    await mkdir(join(repo, "tmp/build/ios/XcodeDerivedData"), { recursive: true })

    expect(await worktreeIsGone(repo)).toBe(true)
  })
})

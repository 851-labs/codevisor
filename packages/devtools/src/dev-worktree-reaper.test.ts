import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it, onTestFinished } from "vitest"

import { claimedInstances, claimInstance, instanceHash } from "./dev-instance-roots.ts"
import {
  reapDeletedWorktrees,
  reapOwnWorktreeIfGone,
  type WorktreeReaper
} from "./dev-worktree-reaper.ts"

const scratch = async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-worktree-reaper-test-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  return root
}

const liveWorktree = async () => {
  const repoRoot = await scratch()
  await writeFile(join(repoRoot, "package.json"), "{}")
  return repoRoot
}

interface Recorded {
  readonly actions: Array<string>
  readonly reaper: WorktreeReaper
}

const recordingReaper = (
  running: ReadonlyArray<{ pid: number; command: string }> = [],
  failing: ReadonlyArray<string> = []
): Recorded => {
  const actions: Array<string> = []
  const step = async (action: string) => {
    if (failing.some((prefix) => action.startsWith(prefix))) throw new Error(`${action} failed`)
    actions.push(action)
  }
  return {
    actions,
    reaper: {
      removeContainers: (hash) => step(`containers ${hash}`),
      readProcessTable: async () => running,
      stopProcesses: (processes) => step(`stop ${processes.map(({ pid }) => pid).join(",")}`),
      purgeAppState: (hash) => step(`app state ${hash}`),
      removeInstanceRoot: (path) => rm(path, { recursive: true, force: true })
    }
  }
}

it("cleans up after worktrees that are gone and leaves the ones still there", async () => {
  const instances = await scratch()
  const live = await liveWorktree()
  const gone = "/repo/worktrees/deleted"
  await claimInstance(live, instances)
  await claimInstance(gone, instances)
  const { actions, reaper } = recordingReaper([
    {
      pid: 11,
      command: `${gone}/tmp/build/macos/Codevisor (deleted).app/Contents/MacOS/Codevisor`
    },
    { pid: 12, command: `${gone}-two/node_modules/.bin/workerd` },
    { pid: 13, command: `${live}/node_modules/.bin/workerd` },
    { pid: 14, command: `/usr/bin/tail -f ${gone}/tmp/dev.log` }
  ])

  const reaped = await reapDeletedWorktrees(reaper, instances)

  expect(reaped).toEqual([gone])
  expect(actions.toSorted()).toEqual([
    `app state ${instanceHash(gone)}`,
    `containers ${instanceHash(gone)}`,
    "stop 11"
  ])
  expect((await claimedInstances(instances)).map(({ repoRoot }) => repoRoot)).toEqual([live])
})

it("keeps a worktree's claim when its cleanup failed, so a later run retries", async () => {
  const instances = await scratch()
  const gone = "/repo/worktrees/deleted"
  await claimInstance(gone, instances)
  const failing = recordingReaper([], ["containers"])

  await expect(reapDeletedWorktrees(failing.reaper, instances)).rejects.toThrow(
    "Could not clean up after /repo/worktrees/deleted"
  )
  const retried = recordingReaper()
  await reapDeletedWorktrees(retried.reaper, instances)

  expect(failing.actions).toEqual([`app state ${instanceHash(gone)}`])
  expect(retried.actions.toSorted()).toEqual([
    `app state ${instanceHash(gone)}`,
    `containers ${instanceHash(gone)}`
  ])
  expect(await claimedInstances(instances)).toEqual([])
})

it("cleans up after its own worktree only once the worktree is gone", async () => {
  const instances = await scratch()
  const repoRoot = await liveWorktree()
  await mkdir(join(repoRoot, "tmp"))
  await claimInstance(repoRoot, instances)
  const { actions, reaper } = recordingReaper()

  const whileThere = await reapOwnWorktreeIfGone(repoRoot, reaper, instances)
  await rm(join(repoRoot, "package.json"))
  const onceGone = await reapOwnWorktreeIfGone(repoRoot, reaper, instances)

  expect([whileThere, onceGone]).toEqual([false, true])
  expect(actions.toSorted()).toEqual([
    `app state ${instanceHash(repoRoot)}`,
    `containers ${instanceHash(repoRoot)}`
  ])
  expect(await claimedInstances(instances)).toEqual([])
})

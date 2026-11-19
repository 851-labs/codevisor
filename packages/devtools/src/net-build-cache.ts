import { join } from "node:path"
import { setTimeout as sleep } from "node:timers/promises"

import { pruneStore, touchStoreEntry } from "./apfs-clone.ts"
import { withArtifactLock } from "./artifact-lock.ts"
import { formatElapsed } from "./build-progress.ts"
import { captureCommand, runCommand } from "./commands.ts"

type Environment = Readonly<Record<string, string | undefined>>

export interface TurboCommand {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

export interface SharedNetTask {
  readonly repoRoot: string
  readonly task: string
  readonly cache: string
  readonly turbo: TurboCommand
  readonly environment: Environment
}

interface PlannedBuild {
  readonly hash: string
  readonly cached: boolean
}

const lockRetryMs = 250
const waitNoticeMs = 20_000

export async function runSharedNetTask(shared: SharedNetTask): Promise<void> {
  const build = await plannedBuild(shared)
  const name = `codevisor-net ${shared.task} ${build.hash}`
  console.log(build.cached ? `${name}: reusing the shared build` : `${name}: no shared build yet`)

  await withArtifactLock(
    join(shared.cache, `.${build.hash}.lock`),
    () => runTurbo(shared, ["--output-logs=new-only"]),
    { retryDelay: waitNotices(name) }
  )
  await retainBuild(shared.cache, build.hash)
}

async function plannedBuild(shared: SharedNetTask): Promise<PlannedBuild> {
  const { command, args } = turboInvocation(shared, ["--dry=json"])
  const plan: unknown = JSON.parse(
    await captureCommand(
      command,
      args,
      { cwd: shared.repoRoot, env: shared.environment },
      "inherit"
    )
  )
  const task = isRecord(plan) && Array.isArray(plan.tasks) ? plan.tasks.find(isRecord) : undefined
  if (task === undefined || typeof task.hash !== "string" || !/^[0-9a-f]+$/.test(task.hash))
    throw new Error(`turbo did not report a hash for ${shared.task}`)

  return { hash: task.hash, cached: isRecord(task.cache) && task.cache.status === "HIT" }
}

async function runTurbo(shared: SharedNetTask, extra: ReadonlyArray<string>): Promise<void> {
  const { command, args } = turboInvocation(shared, extra)
  await runCommand(command, args, { cwd: shared.repoRoot, env: shared.environment })
}

function turboInvocation(shared: SharedNetTask, extra: ReadonlyArray<string>): TurboCommand {
  return {
    command: shared.turbo.command,
    args: [
      ...shared.turbo.args,
      "run",
      shared.task,
      "--filter=@codevisor/net",
      `--cache-dir=${shared.cache}`,
      ...extra
    ]
  }
}

function waitNotices(name: string): () => Promise<void> {
  const started = Date.now()
  let noticed = Number.NEGATIVE_INFINITY
  return async () => {
    if (Date.now() - noticed >= waitNoticeMs) {
      noticed = Date.now()
      console.log(
        `${name}: another worktree is using it; waiting (${formatElapsed(noticed - started)})`
      )
    }
    await sleep(lockRetryMs)
  }
}

async function retainBuild(cache: string, hash: string): Promise<void> {
  const files = [`${hash}.tar.zst`, `${hash}-meta.json`]
  await Promise.all(files.map((file) => touchStoreEntry(cache, file)))
  await pruneStore(cache, Date.now(), new Set(files))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object"
}

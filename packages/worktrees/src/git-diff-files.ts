import { type ChildProcess, execFile } from "node:child_process"
import { finished } from "node:stream"

import type { GitDiffFile } from "@codevisor/api"

import { GitError } from "./git.js"
import { withPriority } from "./low-priority.js"
import { heavyGit } from "./working-state.js"

const maxFiles = 300
const maxFileBytes = 1024 * 1024
const maxTextBytes = 12 * 1024 * 1024
const binarySniffBytes = 8000
const gitlinkMode = "160000"

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })

export const gitBytes = async (
  operation: string,
  args: ReadonlyArray<string>,
  cwd: string,
  env: NodeJS.ProcessEnv | undefined,
  input?: string
): Promise<Buffer> => {
  const command = withPriority("git", args, heavyGit.priority)
  let child!: ChildProcess
  const exited = new Promise<{
    readonly error: Error | null
    readonly stdout: Buffer
    readonly stderr: Buffer
  }>((resolve) => {
    child = execFile(
      command.command,
      command.args,
      { cwd, encoding: "buffer", maxBuffer: heavyGit.maxBuffer, env: env ?? process.env },
      (error, stdout, stderr) => resolve({ error, stdout, stderr })
    )
  })
  const stdin = child.stdin!
  const fed =
    input === undefined
      ? Promise.resolve(undefined)
      : new Promise<Error | undefined>((resolve) => {
          finished(stdin, (error) => resolve(error ?? undefined))
        })
  if (input === undefined) stdin.destroy()
  else stdin.end(input)
  const [run, stdinError] = await Promise.all([exited, fed])
  if (run.error !== null) {
    throw new GitError(operation, run.stderr.toString("utf8").trim() || run.error.message)
  }
  if (stdinError !== undefined) throw new GitError(operation, stdinError.message)
  return run.stdout
}

interface RawChange {
  readonly oldMode: string
  readonly newMode: string
  readonly oldSha: string
  readonly newSha: string
  readonly status: string
  readonly path: string
  readonly oldPath: string
}

const parseRawDiff = (output: Buffer): ReadonlyArray<RawChange> => {
  const fields = output.toString("utf8").split("\0")
  const changes: Array<RawChange> = []
  let index = 0
  while (index < fields.length - 1) {
    const header = fields[index]!.slice(1).split(" ")
    const oldMode = header[0]!
    const newMode = header[1]!
    const oldSha = header[2]!
    const newSha = header[3]!
    const status = header[4]!
    const renamed = status.startsWith("R")
    const oldPath = fields[index + 1]!
    const path = renamed ? fields[index + 2]! : oldPath
    index += renamed ? 3 : 2
    changes.push({ oldMode, newMode, oldSha, newSha, status: status[0]!, path, oldPath })
  }
  return changes
}

const isNullSha = (sha: string): boolean => /^0+$/.test(sha)

const blobSizes = async (
  dir: string,
  shas: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv | undefined
): Promise<ReadonlyMap<string, number>> => {
  const output = await gitBytes(
    "cat-file-check",
    ["cat-file", "--batch-check"],
    dir,
    env,
    shas.map((sha) => `${sha}\n`).join("")
  )
  return new Map(
    output
      .toString("utf8")
      .split("\n")
      .filter((line) => line.length > 0)
      .map((line) => {
        const [sha, , size] = line.split(" ")
        return [sha!, Number(size)]
      })
  )
}

const blobContents = async (
  dir: string,
  shas: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv | undefined
): Promise<ReadonlyMap<string, Buffer>> => {
  const output = await gitBytes(
    "cat-file",
    ["cat-file", "--batch"],
    dir,
    env,
    shas.map((sha) => `${sha}\n`).join("")
  )
  const blobs = new Map<string, Buffer>()
  let offset = 0
  while (offset < output.length) {
    const headerEnd = output.indexOf(10, offset)
    const [sha, , size] = output.subarray(offset, headerEnd).toString("latin1").split(" ")
    const start = headerEnd + 1
    const end = start + Number(size)
    blobs.set(sha!, output.subarray(start, end))
    offset = end + 1
  }
  return blobs
}

const decodeText = (bytes: Buffer): string | undefined => {
  if (bytes.subarray(0, binarySniffBytes).includes(0)) return undefined
  try {
    return utf8.decode(bytes)
  } catch {
    return undefined
  }
}

const fileStatus = (status: string): GitDiffFile["status"] => {
  if (status === "A") return "added"
  if (status === "D") return "deleted"
  if (status === "R") return "renamed"
  return "modified"
}

const sideShas = (change: RawChange): ReadonlyArray<string> =>
  [change.oldSha, change.newSha].filter((sha) => !isNullSha(sha))

const budgetedPlans = (
  kept: ReadonlyArray<RawChange>,
  sizes: ReadonlyMap<string, number>
): ReadonlyArray<{ readonly change: RawChange; readonly tooLarge: boolean }> => {
  let budget = maxTextBytes
  return kept.map((change) => {
    const shaSizes = sideShas(change).map((sha) => sizes.get(sha)!)
    const total = shaSizes.reduce((sum, size) => sum + size, 0)
    const tooLarge = shaSizes.some((size) => size > maxFileBytes) || total > budget
    if (!tooLarge) budget -= total
    return { change, tooLarge }
  })
}

const projectReviewFile = (
  change: RawChange,
  tooLarge: boolean,
  contents: ReadonlyMap<string, Buffer>
): GitDiffFile => {
  const status = fileStatus(change.status)
  const identity = {
    path: change.path,
    ...(status === "renamed" ? { oldPath: change.oldPath } : {}),
    status,
    fingerprint: `${change.oldSha}..${change.newSha}`
  }
  if (tooLarge) return { ...identity, oldText: null, newText: null, omitted: "tooLarge" }
  const oldText = isNullSha(change.oldSha) ? null : decodeText(contents.get(change.oldSha)!)
  const newText = isNullSha(change.newSha) ? null : decodeText(contents.get(change.newSha)!)
  if (oldText === undefined || newText === undefined) {
    return { ...identity, oldText: null, newText: null, omitted: "binary" }
  }
  return { ...identity, oldText, newText }
}

export const diffFiles = async (
  dir: string,
  oldTree: string,
  newTree: string,
  env: NodeJS.ProcessEnv | undefined
): Promise<{ readonly files: ReadonlyArray<GitDiffFile>; readonly truncated: boolean }> => {
  const raw = await gitBytes(
    "diff-tree",
    ["diff-tree", "-r", "-z", "-M", "--raw", oldTree, newTree],
    dir,
    env
  )
  const changes = parseRawDiff(raw)
    .filter((change) => change.oldMode !== gitlinkMode && change.newMode !== gitlinkMode)
    .toSorted((left, right) => Number(left.path > right.path) - Number(left.path < right.path))
  const kept = changes.slice(0, maxFiles)
  const sizes = await blobSizes(dir, [...new Set(kept.flatMap(sideShas))], env)

  const plans = budgetedPlans(kept, sizes)
  const contents = await blobContents(
    dir,
    [...new Set(plans.flatMap((plan) => (plan.tooLarge ? [] : sideShas(plan.change))))],
    env
  )
  const files = plans.map(({ change, tooLarge }) => projectReviewFile(change, tooLarge, contents))
  return { files, truncated: changes.length > maxFiles }
}

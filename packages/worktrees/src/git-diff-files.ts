import { type ChildProcess, execFile } from "node:child_process"
import { finished } from "node:stream"

import type { GitDiffFile } from "@codevisor/api"

import { GitError } from "./git.js"
import { withPriority } from "./low-priority.js"
import { heavyGit } from "./working-state.js"

/// A review response carries whole file texts, so it is bounded in files, per
/// file, and overall; beyond that the client could not render it usefully.
const maxFiles = 300
const maxFileBytes = 1024 * 1024
const maxTextBytes = 12 * 1024 * 1024
/// Git's own binary heuristic: a NUL within the first 8000 bytes.
const binarySniffBytes = 8000
const gitlinkMode = "160000"

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })

/// Plumbing whose output is paths and file contents, so it is read as bytes:
/// `runGit` trims, which would corrupt a path ending in a space or a blob
/// ending in a newline.
///
/// Settles only once both git has exited and its stdin has finished or
/// failed, so the outcome never depends on which of the two is noticed first.
/// Git's own failure wins, since it says why; a git that exited cleanly
/// without reading every request (its stdin broke) produced partial output,
/// which is a failure too.
///
/// Without `input`, stdin is closed without a write: git may never read it,
/// and even ending an empty write on a pipe git already closed breaks it.
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

/// Parses `diff-tree --raw -z`: `:oldmode newmode oldsha newsha status\0path\0`
/// with a second path after a rename's status.
const parseRawDiff = (output: Buffer): ReadonlyArray<RawChange> => {
  const fields = output.toString("utf8").split("\0")
  const changes: Array<RawChange> = []
  let index = 0
  while (index < fields.length - 1) {
    const [oldMode, newMode, oldSha, newSha, status] = fields[index]!.slice(1).split(" ") as [
      string,
      string,
      string,
      string,
      string
    ]
    const renamed = status.startsWith("R")
    const oldPath = fields[index + 1]!
    const path = renamed ? fields[index + 2]! : oldPath
    index += renamed ? 3 : 2
    changes.push({ oldMode, newMode, oldSha, newSha, status: status[0]!, path, oldPath })
  }
  return changes
}

const isNullSha = (sha: string): boolean => /^0+$/.test(sha)

/// Asks one `cat-file` process for every blob at once rather than a process
/// per file side.
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

/// `cat-file --batch` answers `<sha> <type> <size>\n<bytes>\n` per request.
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
  // M, and T for a type change such as a file becoming a symlink.
  return "modified"
}

const sideShas = (change: RawChange): ReadonlyArray<string> =>
  [change.oldSha, change.newSha].filter((sha) => !isNullSha(sha))

const budgetedPlans = (
  kept: ReadonlyArray<RawChange>,
  sizes: ReadonlyMap<string, number>
): ReadonlyArray<{ readonly change: RawChange; readonly tooLarge: boolean }> => {
  // Files are budgeted in path order, so which ones lose their text is stable
  // from one refresh to the next.
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
    // Both sides' blob ids: identical on every client, and different as
    // soon as either side's content changes.
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
  // Submodule commits are not in this repository, so there is no text to show.
  const changes = parseRawDiff(raw)
    .filter((change) => change.oldMode !== gitlinkMode && change.newMode !== gitlinkMode)
    // Rename detection can emit a renamed file at its old path's position.
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

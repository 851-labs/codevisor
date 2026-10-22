import { join } from "node:path"

import { runGit, untrackedLineCount } from "./git.js"

export type GitWorkingChangeStatus = "added" | "modified" | "deleted"

export interface GitWorkingChange {
  readonly path: string
  readonly status: GitWorkingChangeStatus
  readonly added: number
  readonly removed: number
}

export interface GitWorkingChanges {
  readonly files: ReadonlyArray<GitWorkingChange>
  readonly truncated: boolean
}

export const maxGitWorkingChanges = 300

const outputOptions = { maxBuffer: 16 * 1024 * 1024, priority: "utility" } as const

const records = (output: string): ReadonlyArray<string> =>
  output.split("\0").filter((record) => record !== "")

const changeStatus = (code: string): GitWorkingChangeStatus => {
  if (code === "A") return "added"
  if (code === "D") return "deleted"
  return "modified"
}

export const parseNameStatus = (output: string): ReadonlyMap<string, GitWorkingChangeStatus> => {
  const statuses = new Map<string, GitWorkingChangeStatus>()
  const fields = records(output)
  for (let index = 0; index + 1 < fields.length; index += 2) {
    const code = fields[index]!.charAt(0)
    statuses.set(fields[index + 1]!, changeStatus(code))
  }
  return statuses
}

export const parseNumstat = (
  output: string
): ReadonlyMap<string, { readonly added: number; readonly removed: number }> => {
  const counts = new Map<string, { readonly added: number; readonly removed: number }>()
  for (const record of records(output)) {
    const [added, removed, path] = record.split("\t")
    if (path === undefined || path === "") continue
    counts.set(path, {
      added: Number.parseInt(added!, 10) || 0,
      removed: Number.parseInt(removed!, 10) || 0
    })
  }
  return counts
}

const hasHead = async (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<boolean> => {
  try {
    await runGit("head", ["rev-parse", "--verify", "--quiet", "HEAD"], dir, env)
    return true
  } catch {
    return false
  }
}

export const gitWorkingChanges = async (
  dir: string,
  env?: NodeJS.ProcessEnv
): Promise<GitWorkingChanges> => {
  if (!(await hasHead(dir, env))) return { files: [], truncated: false }
  const diff = ["diff", "HEAD", "--relative", "--no-renames", "--no-ext-diff", "-z"]
  const [numstat, nameStatus, untracked] = await Promise.all([
    runGit("working-numstat", [...diff, "--numstat"], dir, env, outputOptions),
    runGit("working-name-status", [...diff, "--name-status"], dir, env, outputOptions),
    runGit(
      "untracked-files",
      ["ls-files", "--others", "--exclude-standard", "-z"],
      dir,
      env,
      outputOptions
    )
  ])
  const counts = parseNumstat(numstat)
  const tracked = [...parseNameStatus(nameStatus)].map(([path, status]): GitWorkingChange => ({
    path,
    status,
    added: counts.get(path)?.added ?? 0,
    removed: counts.get(path)?.removed ?? 0
  }))
  const untrackedPaths = records(untracked).filter((path) => !counts.has(path))
  const total = tracked.length + untrackedPaths.length
  const kept = tracked.slice(0, maxGitWorkingChanges)
  const room = maxGitWorkingChanges - kept.length
  const added = await Promise.all(
    untrackedPaths.slice(0, room).map(async (path): Promise<GitWorkingChange> => ({
      path,
      status: "added",
      added: await untrackedLineCount(join(dir, path)),
      removed: 0
    }))
  )
  return { files: [...kept, ...added], truncated: total > maxGitWorkingChanges }
}

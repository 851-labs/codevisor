import type { GitChangeCode, GitStatus, GitStatusEntry } from "@codevisor/api"

import { assertWorkTree } from "./git-review.js"
import { runGit } from "./git.js"

/// A source control list never needs more rows than this; a checkout with
/// more changes (an unignored build folder) reports `truncated` instead.
const maxEntries = 5000

/// Status listings of large checkouts outgrow Node's 1MB default.
const statusBuffer = { maxBuffer: 64 * 1024 * 1024 }

const codes: Readonly<Record<string, GitChangeCode>> = {
  M: "modified",
  T: "typeChanged",
  A: "added",
  D: "deleted",
  R: "renamed",
  C: "added",
  U: "conflicted"
}

/// The text after `count` space-separated fields: a path, which may itself
/// contain spaces.
const after = (record: string, count: number): string => {
  let index = 0
  for (let field = 0; field < count; field += 1) index = record.indexOf(" ", index) + 1
  return record.slice(index)
}

/// An ordinary or renamed record's two status letters: the index's, then
/// the working tree's. `.` means that side is unchanged.
const changed = (record: string, path: string): GitStatusEntry => {
  const staged = codes[record.slice(2, 3)]
  const unstaged = codes[record.slice(3, 4)]
  return {
    path,
    ...(staged === undefined ? {} : { staged }),
    ...(unstaged === undefined ? {} : { unstaged })
  }
}

/// Parses `git status --porcelain=v2 --branch -z`. Each record is one NUL
/// terminated line, except renames, whose original path follows in a field
/// of its own.
export const parseGitStatus = (
  output: string
): { readonly branch: string | null; readonly entries: ReadonlyArray<GitStatusEntry> } => {
  let branch: string | null = null
  const entries: Array<GitStatusEntry> = []
  let rename: GitStatusEntry | undefined
  for (const record of output.split("\0")) {
    if (rename !== undefined) {
      entries.push({ ...rename, oldPath: record })
      rename = undefined
    } else if (record.startsWith("# branch.head ")) {
      const head = record.slice("# branch.head ".length)
      branch = head === "(detached)" ? null : head
    } else if (record.startsWith("1 ")) {
      entries.push(changed(record, after(record, 8)))
    } else if (record.startsWith("2 ")) {
      rename = changed(record, after(record, 9))
    } else if (record.startsWith("u ")) {
      entries.push({ path: after(record, 10), unstaged: "conflicted" })
    } else if (record.startsWith("? ")) {
      entries.push({ path: record.slice(2), unstaged: "untracked" })
    }
  }
  return { branch, entries }
}

const repositoryRoot = (dir: string, env: NodeJS.ProcessEnv | undefined): Promise<string> =>
  runGit("toplevel", ["rev-parse", "--show-toplevel"], dir, env)

/// The changed files of the repository containing `dir`, untracked files one
/// by one, as a source control list shows them.
export const gitStatus = async (dir: string, env?: NodeJS.ProcessEnv): Promise<GitStatus> => {
  await assertWorkTree(dir)
  const root = await repositoryRoot(dir, env)
  const output = await runGit(
    "status",
    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
    root,
    env,
    statusBuffer
  )
  const { branch, entries } = parseGitStatus(output)
  return {
    repositoryRoot: root,
    branch,
    entries: entries.slice(0, maxEntries),
    truncated: entries.length > maxEntries
  }
}

/// Runs a pathspec command at the repository root. Paths are literal, so a
/// file named `*.ts` or `:(top)` means exactly that file.
const atRoot = async (
  dir: string,
  env: NodeJS.ProcessEnv | undefined,
  run: (git: (operation: string, args: ReadonlyArray<string>) => Promise<string>) => Promise<void>
): Promise<GitStatus> => {
  await assertWorkTree(dir)
  const root = await repositoryRoot(dir, env)
  await run((operation, args) => runGit(operation, ["--literal-pathspecs", ...args], root, env))
  return gitStatus(root, env)
}

const pathspecs = (files: ReadonlyArray<string> | undefined): ReadonlyArray<string> =>
  files === undefined ? [] : ["--", ...files]

/// Stages files (every change when none are given), deletions included.
export const gitStage = (
  dir: string,
  files?: ReadonlyArray<string>,
  env?: NodeJS.ProcessEnv
): Promise<GitStatus> =>
  atRoot(dir, env, async (git) => {
    await git("stage", ["add", "-A", ...pathspecs(files)])
  })

/// Takes files (every staged change when none are given) back out of the
/// index, leaving the working tree alone. Before the first commit there is
/// no HEAD to reset to, so the files leave the index entirely.
export const gitUnstage = (
  dir: string,
  files?: ReadonlyArray<string>,
  env?: NodeJS.ProcessEnv
): Promise<GitStatus> =>
  atRoot(dir, env, async (git) => {
    const hasHead = await git("head", ["rev-parse", "--verify", "--quiet", "HEAD"]).then(
      () => true,
      () => false
    )
    if (hasHead) await git("unstage", ["reset", "-q", ...pathspecs(files)])
    else await git("unstage", ["rm", "--cached", "-r", "-q", ...pathspecs(files ?? ["."])])
  })

/// Throws away files' unstaged changes: tracked files return to their staged
/// (or committed) content, untracked files are deleted.
export const gitDiscard = (
  dir: string,
  files: ReadonlyArray<string>,
  env?: NodeJS.ProcessEnv
): Promise<GitStatus> =>
  atRoot(dir, env, async (git) => {
    if (files.length === 0) return
    const untracked = new Set(
      (
        await git("untracked", [
          "ls-files",
          "--others",
          "--exclude-standard",
          "-z",
          ...pathspecs(files)
        ])
      )
        .split("\0")
        .filter((path) => path !== "")
    )
    const tracked = files.filter((file) => !untracked.has(file))
    if (untracked.size > 0)
      await git("discard-untracked", ["clean", "-f", "-q", ...pathspecs([...untracked])])
    if (tracked.length > 0) await git("discard", ["restore", "--worktree", ...pathspecs(tracked)])
  })

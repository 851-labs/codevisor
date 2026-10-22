import { realpath } from "node:fs/promises"

import { nonInteractiveGitEnvironment, probeRemote } from "./git-clone.js"
import { CloneError, classifyCloneFailure, type CloneFailureCode } from "./git-errors.js"
import { runGit } from "./git.js"

export type PublishFailureCode = CloneFailureCode | "push_rejected" | "identity_missing"

export class PublishError extends Error {
  constructor(
    message: string,
    readonly code: PublishFailureCode | undefined
  ) {
    super(message)
    this.name = "PublishError"
  }
}

const envFileExclusions = [".env", ".env.*", ".envrc", ".dev.vars", ".dev.vars.*"].map(
  (pattern) => `:(exclude,glob)**/${pattern}`
)

const succeeds = (promise: Promise<unknown>): Promise<boolean> =>
  promise.then(
    () => true,
    () => false
  )

export const ownsRepository = async (
  folderPath: string,
  env?: NodeJS.ProcessEnv
): Promise<boolean> => {
  const topLevel = await runGit(
    "toplevel",
    ["rev-parse", "--show-toplevel"],
    folderPath,
    env
  ).catch(() => undefined)
  if (topLevel === undefined) return false
  const [top, folder] = await Promise.all([realpath(topLevel), realpath(folderPath)])
  return top === folder
}

export const hasCommits = (folderPath: string, env?: NodeJS.ProcessEnv): Promise<boolean> =>
  succeeds(runGit("head", ["rev-parse", "--verify", "-q", "HEAD"], folderPath, env))

export const needsInitialCommit = async (
  folderPath: string,
  env?: NodeJS.ProcessEnv
): Promise<boolean> =>
  !(await ownsRepository(folderPath, env)) || !(await hasCommits(folderPath, env))

const classifyPushFailure = (message: string): PublishFailureCode | undefined => {
  if (message.includes("[rejected]")) return "push_rejected"
  return classifyCloneFailure(message)
}

const commitEverything = async (folderPath: string, env: NodeJS.ProcessEnv): Promise<void> => {
  if (!(await ownsRepository(folderPath, env))) await runGit("init", ["init"], folderPath, env)
  if (await hasCommits(folderPath, env)) return
  await runGit("add", ["add", "-A", "--", ".", ...envFileExclusions], folderPath, env)
  const failure = await runGit(
    "commit",
    ["commit", "--allow-empty", "--no-verify", "-m", "Initial commit"],
    folderPath,
    env
  ).then(
    () => undefined,
    (cause: Error) => cause
  )
  if (failure === undefined) return
  const text = failure.message.toLowerCase()
  const missingIdentity = text.includes("tell me who you are") || text.includes("empty ident")
  throw new PublishError(failure.message, missingIdentity ? "identity_missing" : undefined)
}

export const publishToRemote = async (
  folderPath: string,
  url: string,
  options: { readonly initialize: boolean; readonly env?: NodeJS.ProcessEnv }
): Promise<void> => {
  const baseEnv = options.env ?? process.env
  const probe = await probeRemote(url, baseEnv)
  if (!probe.ok) throw new CloneError(probe.message, probe.code)
  const env = nonInteractiveGitEnvironment(baseEnv)
  if (options.initialize) await commitEverything(folderPath, env)
  await runGit("remote-add", ["remote", "add", "origin", url], folderPath, env)
  const failure = await runGit(
    "push",
    ["push", "--set-upstream", "origin", "HEAD"],
    folderPath,
    env
  ).then(
    () => undefined,
    (cause: Error) => cause
  )
  if (failure === undefined) return
  await runGit("remote-remove", ["remote", "remove", "origin"], folderPath, env)
  throw new PublishError(failure.message, classifyPushFailure(failure.message))
}

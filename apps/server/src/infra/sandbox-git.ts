import {
  GIT_SIGN_IN_REQUIRED,
  gitHostProvider,
  repoIdentityKey,
  type AppliedGitSignIn,
  type GitHostProvider,
  type GitSignIn
} from "@codevisor/api"
import { cloneUrlHost } from "@codevisor/worktrees"

import { HttpFailure } from "../server-context.js"
import { field } from "../unknown-values.js"
import { copiesToSandboxes, type SavedGitSignIns } from "./git-sign-ins.js"
import type { SandboxRemote } from "./sandbox-remote.js"
import type { SandboxSetupProgress } from "./sandbox-setup-log.js"

export interface SandboxGitDeps {
  readonly gitSignIns: SavedGitSignIns
  readonly machineName: () => string
  readonly log: (line: string) => void
}

export interface SandboxGitAccess {
  readonly signIns: ReadonlyArray<AppliedGitSignIn>
}

export const NO_GIT_ACCESS: SandboxGitAccess = { signIns: [] }

export const requireGitSignIn = async (
  deps: SandboxGitDeps,
  repoUrl: string | undefined
): Promise<void> => {
  const host = sandboxGitHost(repoUrl)
  if (host === undefined) return

  const saved = await deps.gitSignIns.saved()
  if (saved.some((signIn) => signIn.host === host)) return

  throw new HttpFailure(
    409,
    signInRequiredMessage(host, deps.machineName()),
    GIT_SIGN_IN_REQUIRED,
    {
      host
    }
  )
}

export const copyGitSignIns = async (
  git: SavedGitSignIns,
  remote: SandboxRemote
): Promise<ReadonlyArray<AppliedGitSignIn>> => sendGitSignIns(remote, await git.saved())

export const signInToGit = async (
  deps: SandboxGitDeps,
  remote: SandboxRemote,
  setup: SandboxSetupProgress
): Promise<SandboxGitAccess> => {
  try {
    const saved = await deps.gitSignIns.saved()
    if (saved.length === 0) setup.log(notSignedInLine(deps.machineName()))

    const signIns = await sendGitSignIns(remote, saved)
    for (const signIn of signIns) setup.log(copyLine(signIn, deps.machineName()))
    return { signIns }
  } catch (cause) {
    deps.log(`Copying git sign-ins to a sandbox failed: ${messageOf(cause)}`)
    setup.log(`Couldn't copy ${deps.machineName()}'s GitHub sign-in to this sandbox`, "stderr")
    return NO_GIT_ACCESS
  }
}

export const cloneFailure = (
  cause: unknown,
  repoUrl: string,
  access: SandboxGitAccess,
  machineName: string
): Error => {
  const host = cloneUrlHost(repoUrl) ?? "the git host"
  const repository = repositoryName(repoUrl)
  const reason = cloneFailureReason(field(cause, "code"), { host, access, machineName })
  if (reason === undefined) return new Error(`Couldn't clone ${repository}: ${messageOf(cause)}`)
  return new Error(`Couldn't clone ${repository}. ${reason}`)
}

interface CloneFailureContext {
  readonly host: string
  readonly access: SandboxGitAccess
  readonly machineName: string
}

const cloneFailureReason = (code: unknown, context: CloneFailureContext): string | undefined => {
  if (code === "auth_failed" || code === "repo_not_found") return noAccessReason(context)
  if (code === "network") {
    return `The sandbox couldn't reach ${context.host}. Check the sandbox's network access, then try again.`
  }
  if (code === "disk_full")
    return "The sandbox ran out of disk space. Give its profile a larger disk."
  if (code === "invalid_url")
    return "Its remote URL isn't a git repository. Check the project's remote."
  return undefined
}

const noAccessReason = ({ host, access, machineName }: CloneFailureContext): string => {
  const service = hostDisplayName(host)
  const signIn = access.signIns.find((candidate) => candidate.host === host)
  if (signIn === undefined) {
    return `The sandbox isn't signed in to ${service}, so it can only open public repositories. ${signInAdvice(host, machineName)}`
  }
  if (!signIn.signedIn) {
    return `The sandbox couldn't sign in to ${service} with ${machineName}'s sign-in${detailOf(signIn.message)}. Sign in to ${service} on ${machineName} again, then try again.`
  }
  return `${accountOf(signIn, service)} can't open this repository, or it doesn't exist. Check the project's remote URL and that this account has access to it.`
}

const signInAdvice = (host: string, machineName: string): string => {
  if (copiesToSandboxes(host)) {
    return `Sign in to ${hostDisplayName(host)} on ${machineName}, then try again.`
  }
  return `Codevisor can't copy a ${hostDisplayName(host)} sign-in to a sandbox yet.`
}

const signInRequiredMessage = (host: string, machineName: string): string =>
  `Sign in to ${hostDisplayName(host)} on ${machineName} first. A sandbox uses that sign-in to clone, fetch and push; without it this project's repository can't be pushed from the sandbox.`

const sendGitSignIns = async (
  remote: SandboxRemote,
  signIns: ReadonlyArray<GitSignIn>
): Promise<ReadonlyArray<AppliedGitSignIn>> => {
  if (signIns.length === 0) return []

  return appliedIn(await remote.request("PUT", "/v1/git/auth/sign-ins", { signIns }))
}

const notSignedInLine = (machineName: string): string =>
  `${machineName} isn't signed in to GitHub: this sandbox can only read public repositories and can't push`

const copyLine = (signIn: AppliedGitSignIn, machineName: string): string => {
  const service = hostDisplayName(signIn.host)
  if (!signIn.signedIn) {
    return `Couldn't sign in to ${service} with ${machineName}'s sign-in${detailOf(signIn.message)}`
  }
  return `Signed in to ${service} as ${signIn.account ?? "your account"}, copied from ${machineName}`
}

const sandboxGitHost = (repoUrl: string | undefined): string | undefined => {
  const host = repoUrl === undefined ? undefined : cloneUrlHost(repoUrl)
  if (host === undefined || !copiesToSandboxes(host)) return undefined
  return host
}

const repositoryName = (repoUrl: string): string => {
  const identity = repoIdentityKey(repoUrl)
  if (identity === undefined) return repoUrl
  return identity.split("/").slice(1).join("/")
}

const accountOf = (signIn: AppliedGitSignIn, service: string): string => {
  if (signIn.account === undefined) return `Your ${service} account`
  return `${signIn.account} on ${service}`
}

const detailOf = (message: string | undefined): string => {
  const detail = message?.trim() ?? ""
  if (detail.length === 0) return ""
  return ` (${detail})`
}

const providerNames: Readonly<Record<GitHostProvider, string>> = {
  github: "GitHub",
  gitlab: "GitLab",
  bitbucket: "Bitbucket"
}

const hostDisplayName = (host: string): string => {
  const provider = gitHostProvider(host)
  if (provider === undefined) return host
  return providerNames[provider]
}

const appliedIn = (answer: unknown): ReadonlyArray<AppliedGitSignIn> => {
  const applied = field(answer, "applied")
  if (!Array.isArray(applied)) return []
  return applied.flatMap(appliedSignIn)
}

const appliedSignIn = (value: unknown): ReadonlyArray<AppliedGitSignIn> => {
  const host = field(value, "host")
  if (typeof host !== "string") return []
  const account = field(value, "account")
  const message = field(value, "message")
  return [
    {
      host,
      signedIn: field(value, "signedIn") === true,
      ...(typeof account === "string" ? { account } : {}),
      ...(typeof message === "string" ? { message } : {})
    }
  ]
}

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

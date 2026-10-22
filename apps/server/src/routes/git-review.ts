import { statSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"

import { GitDiffMode, type GitPullRequest } from "@codevisor/api"
import type { GitHosts, OwnedBranch } from "@codevisor/git-hosts"
import {
  gitCurrentBranch,
  gitDiff,
  gitRefs,
  GitReviewError,
  type GitReviewFailureCode
} from "@codevisor/worktrees"
import { Schema } from "effect"

import { gitHostsOf } from "../infra/git-hosts.js"
import { HttpFailure, writeJson, type CodevisorServerServices } from "../server-context.js"
import { folderOwnedBranch } from "../workspace-owned-branch.js"
import { expandFsPath } from "./fs-paths.js"

const failureStatus: Readonly<Record<GitReviewFailureCode, number>> = {
  not_git_repository: 422,
  unknown_base: 422,
  no_turn_snapshot: 404,
  unmerged_index: 409
}

const isGitDiffMode = Schema.is(GitDiffMode)

const requestedDirectory = (url: URL): string => {
  const path = expandFsPath(url.searchParams.get("path") ?? "")
  let isDirectory: boolean
  try {
    isDirectory = statSync(path).isDirectory()
  } catch {
    throw new HttpFailure(404, `No such directory: ${path}`, "not_found")
  }
  if (!isDirectory) throw new HttpFailure(400, `Not a directory: ${path}`, "not_a_directory")
  return path
}

const pullRequestTtlMs = 60_000

const pullRequests = new Map<
  string,
  { readonly at: number; readonly lookup: Promise<GitPullRequest | null> }
>()

export interface PullRequestQuery {
  readonly branch?: string | undefined
  readonly owned?: OwnedBranch | undefined
}

export const cachedPullRequest = (
  hosts: GitHosts,
  directory: string,
  env: NodeJS.ProcessEnv,
  { branch, owned }: PullRequestQuery = {},
  now = Date.now()
): Promise<GitPullRequest | null> => {
  for (const [key, entry] of pullRequests) {
    if (now - entry.at >= pullRequestTtlMs) pullRequests.delete(key)
  }
  const key = [directory, branch ?? "", owned?.name ?? "", owned?.ownedSince ?? ""].join("\0")
  const cached = pullRequests.get(key)
  if (cached !== undefined) return cached.lookup
  const lookup = branchPullRequest(hosts, directory, env, { branch, owned })
  pullRequests.set(key, { at: now, lookup })
  return lookup
}

const branchPullRequest = async (
  hosts: GitHosts,
  directory: string,
  env: NodeJS.ProcessEnv,
  { branch, owned }: PullRequestQuery
): Promise<GitPullRequest | null> => {
  const current = branch ?? (await gitCurrentBranch(directory, env))
  if (current === null || current.length === 0) return null

  return (await hosts.github.findPullRequest(directory, env, current, owned)) ?? null
}

const gitReviewPaths = new Set(["/v1/fs/git/diff", "/v1/fs/git/refs", "/v1/fs/git/pull-request"])

export const routeGitReview = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method !== "GET") return false
  if (!gitReviewPaths.has(url.pathname)) return false
  const directory = requestedDirectory(url)
  const env = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  try {
    if (url.pathname === "/v1/fs/git/refs") {
      writeJson(response, 200, await gitRefs(directory, env))
      return true
    }
    if (url.pathname === "/v1/fs/git/pull-request") {
      const owned = await folderOwnedBranch(services, directory)
      const pullRequest = await cachedPullRequest(gitHostsOf(services), directory, env, { owned })
      writeJson(response, 200, { pullRequest })
      return true
    }
    const mode = url.searchParams.get("mode")
    if (!isGitDiffMode(mode)) {
      throw new HttpFailure(400, `Unknown review mode: ${String(mode)}`, "invalid_mode")
    }
    const base = url.searchParams.get("base") ?? undefined
    const knownRevision = url.searchParams.get("revision") ?? undefined
    writeJson(
      response,
      200,
      await gitDiff(directory, mode, {
        env,
        ...(base === undefined ? {} : { base }),
        ...(knownRevision === undefined ? {} : { knownRevision })
      })
    )
    return true
  } catch (cause) {
    if (!(cause instanceof GitReviewError)) throw cause
    throw new HttpFailure(failureStatus[cause.code], cause.message, cause.code)
  }
}

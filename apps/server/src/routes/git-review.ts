import { statSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"

import { GitDiffMode } from "@codevisor/api"
import { gitDiff, gitRefs, GitReviewError, type GitReviewFailureCode } from "@codevisor/worktrees"
import { Schema } from "effect"

import { HttpFailure, writeJson, type CodevisorServerServices } from "../server-context.js"
import { expandFsPath } from "./fs-paths.js"

const failureStatus: Readonly<Record<GitReviewFailureCode, number>> = {
  not_git_repository: 422,
  unknown_base: 422,
  no_turn_snapshot: 404,
  unmerged_index: 409
}

const isGitDiffMode = Schema.is(GitDiffMode)

/// The review pane addresses a folder the way the other fs routes do, so a
/// missing folder reads the same everywhere.
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

/// Git review for the Review pane: the diff of one comparison mode, and the
/// branches branch mode can compare against. Both read-only.
export const routeGitReview = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method !== "GET") return false
  if (url.pathname !== "/v1/fs/git/diff" && url.pathname !== "/v1/fs/git/refs") return false
  const directory = requestedDirectory(url)
  const env = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  try {
    if (url.pathname === "/v1/fs/git/refs") {
      writeJson(response, 200, await gitRefs(directory, env))
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

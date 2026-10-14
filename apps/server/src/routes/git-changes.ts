import type { IncomingMessage, ServerResponse } from "node:http"

import { GitFilesRequest, type GitStatus } from "@codevisor/api"
import {
  GitError,
  gitDiscard,
  gitStage,
  gitStatus,
  gitUnstage,
  GitReviewError
} from "@codevisor/worktrees"

import {
  HttpFailure,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"
import { gitDirectory, gitEnvironment, gitFailureStatus, requestedDirectory } from "./git-review.js"

type GitChange = (
  directory: string,
  files: ReadonlyArray<string> | undefined,
  env: NodeJS.ProcessEnv
) => Promise<GitStatus>

const changes: Readonly<Record<string, GitChange>> = {
  "/v1/fs/git/stage": (directory, files, env) => gitStage(directory, files, env),
  "/v1/fs/git/unstage": (directory, files, env) => gitUnstage(directory, files, env),
  // Discarding everything at once is too easy to send by accident: the
  // client always names the files.
  "/v1/fs/git/discard": (directory, files, env) => gitDiscard(directory, files ?? [], env)
}

/// Source control for the navigator: the repository's changed files, and
/// staging, unstaging, and discarding them. Every change answers with the
/// status that follows, so the list updates without another request.
export const routeGitChanges = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const isStatus = request.method === "GET" && url.pathname === "/v1/fs/git/status"
  const change = request.method === "POST" ? changes[url.pathname] : undefined
  if (!isStatus && change === undefined) return false
  const env = await gitEnvironment(services)
  try {
    if (change === undefined) {
      writeJson(response, 200, await gitStatus(requestedDirectory(url), env))
      return true
    }
    const body = await readSchema(request, GitFilesRequest)
    writeJson(response, 200, await change(gitDirectory(body.path), body.files, env))
    return true
  } catch (cause) {
    if (cause instanceof GitReviewError) {
      throw new HttpFailure(gitFailureStatus[cause.code], cause.message, cause.code)
    }
    // Git refused the change (a locked index, a path it no longer knows):
    // its own message is what the user can act on.
    if (cause instanceof GitError) throw new HttpFailure(422, cause.message, "git_failed")
    throw cause
  }
}

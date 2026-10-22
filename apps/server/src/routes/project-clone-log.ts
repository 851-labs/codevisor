import { cloneUrlHost, cloneUrlScheme, type CloneFailureCode } from "@codevisor/worktrees"

export interface CloneFailure {
  readonly code?: CloneFailureCode | undefined
  readonly message: string
}

export const logCloneFailure = (url: string, failure: CloneFailure): void => {
  console.error(
    JSON.stringify({
      event: "project_clone_failed",
      code: failure.code,
      host: cloneUrlHost(url),
      scheme: cloneUrlScheme(url),
      stderr: redactCredentials(failure.message)
    })
  )
}

export const redactCredentials = (text: string): string =>
  text.replace(urlUserInfoPattern, "$1<redacted>@").replace(tokenPattern, "$1<redacted>")

const urlUserInfoPattern = /\b([a-z][a-z0-9+.-]*:\/\/)[^\s/@]+@/gi
const tokenPattern = /\b(gh[pousr]_|github_pat_|glpat-)[\w-]+/g

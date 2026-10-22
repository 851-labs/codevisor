export class GitError extends Error {
  constructor(
    readonly operation: string,
    message: string
  ) {
    super(message)
    this.name = "GitError"
  }
}

export type CloneFailureCode =
  | "auth_failed"
  | "repo_not_found"
  | "network"
  | "disk_full"
  | "invalid_url"
  | "cancelled"

export const classifyCloneFailure = (
  stderrText: string
): Exclude<CloneFailureCode, "cancelled"> | undefined => {
  const text = stderrText.toLowerCase()
  if (
    text.includes("authentication failed") ||
    text.includes("could not read username") ||
    text.includes("could not read password") ||
    text.includes("permission denied (publickey") ||
    text.includes("host key verification failed") ||
    text.includes("support for password authentication was removed")
  ) {
    return "auth_failed"
  }
  if (text.includes("repository") && text.includes("not found")) {
    return "repo_not_found"
  }
  if (
    text.includes("could not resolve host") ||
    text.includes("unable to access") ||
    text.includes("connection timed out") ||
    text.includes("connection refused")
  ) {
    return "network"
  }
  if (text.includes("no space left on device")) {
    return "disk_full"
  }
  if (
    text.includes("does not appear to be a git repository") ||
    text.includes("is not a valid repository name")
  ) {
    return "invalid_url"
  }
  return undefined
}

export class CloneError extends GitError {
  constructor(
    message: string,
    readonly code: CloneFailureCode | undefined
  ) {
    super("clone", message)
    this.name = "CloneError"
  }
}

export const gitFailureMessage = (cause: Error, stderr: string): string => {
  if (stderr.trim().length > 0) return stderr.trim()
  return cause.message
}

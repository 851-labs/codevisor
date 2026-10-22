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
  if (credentialsMissingOrRejected(text)) return "auth_failed"
  if (repositoryNotFound(text)) return "repo_not_found"
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

const credentialsMissingOrRejected = (text: string): boolean =>
  text.includes("authentication failed") ||
  text.includes("could not read username") ||
  text.includes("could not read password") ||
  text.includes("permission denied (publickey")

const repositoryNotFound = (text: string): boolean =>
  text.includes("repository not found") || /repository '[^']*' not found/.test(text)

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

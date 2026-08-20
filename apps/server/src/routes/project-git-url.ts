/// Derives the managed checkout directory name from the remote URL
/// ("git@github.com:acme/widget.git" → "widget").
export const cloneDirectoryName = (url: string): string | undefined => {
  const trimmed = url.trim().replace(/\/+$/, "")
  /* v8 ignore next -- a URL that passed looksLikeGitUrl always has at least one non-separator segment. */
  const last = trimmed.split(/[/:]/).findLast((segment) => segment.length > 0) ?? ""
  const name = last.replace(/\.git$/i, "")
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) ? name : undefined
}

export const looksLikeGitUrl = (url: string): boolean =>
  /^(https?:\/\/|git:\/\/|ssh:\/\/)[^\s]+$/.test(url) ||
  /^[\w.-]+@[\w.-]+:[^\s]+$/.test(url) ||
  url.startsWith("file://")

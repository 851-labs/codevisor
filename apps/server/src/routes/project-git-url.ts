export const cloneDirectoryName = (url: string): string | undefined => {
  const trimmed = url.trim().replace(/\/+$/, "")
  /* v8 ignore next */
  const last = trimmed.split(/[/:]/).findLast((segment) => segment.length > 0) ?? ""
  const name = last.replace(/\.git$/i, "")
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) ? name : undefined
}

export const looksLikeGitUrl = (url: string): boolean =>
  /^(https?:\/\/|git:\/\/|ssh:\/\/)[^\s]+$/.test(url) ||
  /^[\w.-]+@[\w.-]+:[^\s]+$/.test(url) ||
  url.startsWith("file://")

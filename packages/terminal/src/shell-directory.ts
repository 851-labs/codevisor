const KITTY_SCHEME = "kitty-shell-cwd://"
const FILE_SCHEME = "file://"

export const shellDirectory = (reported: string): string | undefined => {
  if (reported.startsWith("/")) return reported
  if (reported.startsWith(KITTY_SCHEME)) return pathAfterHost(reported, KITTY_SCHEME)

  const encoded = reported.startsWith(FILE_SCHEME)
    ? pathAfterHost(reported, FILE_SCHEME)
    : undefined
  return encoded === undefined ? undefined : decodePath(encoded)
}

const pathAfterHost = (url: string, scheme: string): string | undefined => {
  const slash = url.indexOf("/", scheme.length)
  return slash === -1 ? undefined : url.slice(slash)
}

const decodePath = (encoded: string): string | undefined => {
  try {
    return decodeURIComponent(encoded)
  } catch {
    return undefined
  }
}

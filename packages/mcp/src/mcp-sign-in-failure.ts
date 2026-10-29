export const signInFailure = (cause: unknown, serverUrl: string): unknown => {
  if (!isFetchFailure(cause)) return cause
  return new Error(unreachableSignIn(new URL(serverUrl).host), { cause })
}

const isFetchFailure = (cause: unknown): boolean =>
  cause instanceof TypeError && cause.message === "fetch failed"

const unreachableSignIn = (host: string): string =>
  `Couldn't reach ${host}. Check your network connection and try again.`

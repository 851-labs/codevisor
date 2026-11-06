const transientPatterns =
  /error connecting|timed? ?out|Something went wrong|Internal Server Error|Bad Gateway|Service Unavailable|HTTP 50\d/i

export function isTransientGitHubError(stderr: string): boolean {
  return transientPatterns.test(stderr)
}

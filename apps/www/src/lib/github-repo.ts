export const GITHUB_REPO_URL = "https://github.com/851-labs/codevisor"
export const GITHUB_REPO_API_URL = "https://api.github.com/repos/851-labs/codevisor"

export const githubRequestHeaders = (token: string | undefined): Record<string, string> => {
  const headers = { accept: "application/vnd.github+json", "user-agent": "codevisor-www" }
  if (token === undefined || token === "") return headers
  return { ...headers, authorization: `Bearer ${token}` }
}

export const parseStars = (body: unknown): number | null => {
  if (typeof body !== "object" || body === null || !("stargazers_count" in body)) return null
  const stars = body.stargazers_count
  return typeof stars === "number" ? stars : null
}

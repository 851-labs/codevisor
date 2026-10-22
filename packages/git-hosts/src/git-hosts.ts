import { gitHostProvider } from "@codevisor/api"

import type { GitHost, PullRequestHost } from "./git-host.js"
import { githubHost } from "./github-host.js"
import { gitlabHost } from "./gitlab-host.js"

export interface GitHosts {
  readonly github: GitHost & PullRequestHost
  readonly gitlab: GitHost
  readonly forHost: (hostname: string) => GitHost | undefined
}

export const makeGitHosts = (): GitHosts => {
  const github = githubHost()
  const gitlab = gitlabHost()
  return {
    github,
    gitlab,
    forHost: (hostname) => {
      const provider = gitHostProvider(hostname)
      if (provider === "github") return github
      if (provider === "gitlab") return gitlab
      return undefined
    }
  }
}

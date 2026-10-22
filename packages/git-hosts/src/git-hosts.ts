import { gitHostProvider } from "@codevisor/api"

import type { CliPlatform } from "./cli-release.js"
import type { GitHost, PullRequestHost } from "./git-host.js"
import { githubHost } from "./github-host.js"
import { gitlabHost } from "./gitlab-host.js"

export interface GitHosts {
  readonly github: GitHost & PullRequestHost
  readonly gitlab: GitHost
  readonly forHost: (hostname: string) => GitHost | undefined
}

export interface GitHostsOptions {
  readonly toolsDir?: string
  readonly platform?: CliPlatform
  readonly releasesUrls?: { readonly github?: string; readonly gitlab?: string }
}

export const makeGitHosts = (options: GitHostsOptions = {}): GitHosts => {
  const { toolsDir, platform, releasesUrls } = options
  const github = githubHost({ toolsDir, platform, releasesUrl: releasesUrls?.github })
  const gitlab = gitlabHost({ toolsDir, platform, releasesUrl: releasesUrls?.gitlab })
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

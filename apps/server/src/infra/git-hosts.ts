import { makeGitHosts, type GitHosts } from "@codevisor/git-hosts"

import type { CodevisorServerServices } from "../server-context-types.js"

const pathOnlyGitHosts = makeGitHosts()

export const gitHostsOf = (services: Pick<CodevisorServerServices, "gitHosts">): GitHosts =>
  services.gitHosts ?? pathOnlyGitHosts

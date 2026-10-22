import { describe, expect, it } from "vitest"

import { makeGitHosts } from "./git-hosts.js"

describe("makeGitHosts", () => {
  it("picks the CLI-backed host for a hostname", () => {
    const hosts = makeGitHosts()

    expect(hosts.forHost("GitHub.com")).toBe(hosts.github)
    expect(hosts.forHost("gitlab.example.org")).toBe(hosts.gitlab)
    expect(hosts.forHost("bitbucket.org")).toBeUndefined()
    expect(hosts.forHost("git.example.org")).toBeUndefined()
  })
})

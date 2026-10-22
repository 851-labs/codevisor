import { describe, expect, it } from "vitest"

import { classifyCloneFailure } from "./git-errors.js"

describe("classifyCloneFailure", () => {
  it("maps what git prints for each GitHub failure onto the matching code", () => {
    const cases: ReadonlyArray<readonly [string, string, string | undefined]> = [
      [
        "https, no credentials, missing or private repo",
        "remote: Repository not found.\nfatal: Authentication failed for 'https://github.com/acme/gone/'",
        "auth_failed"
      ],
      [
        "https, prompts disabled and no askpass",
        "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
        "auth_failed"
      ],
      [
        "https, rejected credentials",
        "remote: Invalid username or token. Password authentication is not supported for Git operations.\nfatal: Authentication failed for 'https://github.com/acme/gone/'",
        "auth_failed"
      ],
      [
        "https, signed in but the repo is deleted or hidden",
        "remote: Repository not found.\nfatal: repository 'https://github.com/acme/gone/' not found",
        "repo_not_found"
      ],
      [
        "ssh, no accepted key",
        "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.",
        "auth_failed"
      ],
      [
        "ssh, signed in but the repo is deleted or hidden",
        "ERROR: Repository not found.\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.",
        "repo_not_found"
      ],
      [
        "ssh, unknown host key",
        "Host key verification failed.\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.",
        undefined
      ],
      [
        "unresolvable host",
        "fatal: unable to access 'https://x/': Could not resolve host: x",
        "network"
      ],
      ["ssh timeout", "ssh: connect to host x port 22: Connection timed out", "network"],
      ["ssh refused", "ssh: connect to host x port 22: Connection refused", "network"],
      ["full disk", "fatal: write error: No space left on device", "disk_full"],
      ["local path", "fatal: 'x' does not appear to be a git repository", "invalid_url"],
      ["bad name", "remote: is not a valid repository name", "invalid_url"],
      ["anything else", "fatal: something novel exploded", undefined]
    ]
    for (const [name, stderr, expected] of cases) {
      expect(classifyCloneFailure(stderr), name).toBe(expected)
    }
  })
})

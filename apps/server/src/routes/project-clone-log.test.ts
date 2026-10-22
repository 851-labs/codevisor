import { describe, expect, it } from "vitest"

import { redactCredentials } from "./project-clone-log.js"

describe("clone failure logs", () => {
  it("redacts credentials in URLs and tokens git echoes back", () => {
    const cases: ReadonlyArray<readonly [string, string]> = [
      [
        "fatal: unable to access 'https://dylan:hunter2@github.com/acme/widget/'",
        "fatal: unable to access 'https://<redacted>@github.com/acme/widget/'"
      ],
      [
        "fatal: Authentication failed for 'https://ghp_abc123@github.com/acme/widget/'",
        "fatal: Authentication failed for 'https://<redacted>@github.com/acme/widget/'"
      ],
      [
        "remote: token github_pat_11AB_cd was revoked",
        "remote: token github_pat_<redacted> was revoked"
      ],
      ["remote: token glpat-x_Y-z expired", "remote: token glpat-<redacted> expired"],
      [
        "git@github.com: Permission denied (publickey).",
        "git@github.com: Permission denied (publickey)."
      ]
    ]
    for (const [stderr, expected] of cases) {
      expect(redactCredentials(stderr)).toBe(expected)
    }
  })
})

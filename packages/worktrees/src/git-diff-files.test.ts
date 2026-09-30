import { describe, expect, it } from "vitest"

import { gitBytes } from "./git-diff-files.js"
import { GitError } from "./git.js"

/// Far beyond any pipe buffer, so a git that stops reading always leaves the
/// write failing with EPIPE rather than parked in the buffer.
const flood = "0".repeat(8 * 1024 * 1024)

describe("gitBytes", () => {
  it("reports git's own failure, not the broken pipe, when git exits before reading", async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const failure = gitBytes(
        "bogus",
        ["cat-file", "--no-such-option"],
        process.cwd(),
        undefined,
        flood
      )
      await expect(failure).rejects.toBeInstanceOf(GitError)
      await expect(failure).rejects.toMatchObject({ operation: "bogus" })
      await expect(failure).rejects.not.toMatchObject({ message: expect.stringContaining("EPIPE") })
    }
  })

  it("fails when git exits cleanly without reading every request", async () => {
    await expect(
      gitBytes("version", ["--version"], process.cwd(), undefined, flood)
    ).rejects.toMatchObject({ operation: "version", message: expect.stringContaining("EPIPE") })
  })

  it("falls back to the spawn error when git never ran", async () => {
    await expect(
      gitBytes("missing", ["--version"], "/codevisor-no-such-directory", undefined, "a\n")
    ).rejects.toMatchObject({ operation: "missing", message: expect.stringContaining("ENOENT") })
  })

  it("returns git's output when it reads all of its input", async () => {
    const output = await gitBytes(
      "hash",
      ["hash-object", "--stdin"],
      process.cwd(),
      undefined,
      "a\n"
    )
    expect(output.toString("utf8")).toMatch(/^[0-9a-f]{40,64}\n$/)
  })
})

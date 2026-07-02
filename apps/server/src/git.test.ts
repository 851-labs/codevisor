import { describe, expect, it } from "vitest"
import { GitError, addWorktree } from "./git.js"

describe("git helper", () => {
  it("wraps spawn failures without stderr as GitError", async () => {
    // A nonexistent cwd fails before git can write to stderr, so the error
    // message comes from the spawn error itself.
    const failure = await addWorktree(
      "/nonexistent-herdman-repo",
      "/tmp/nonexistent-herdman-worktree",
      "herdman/none"
    ).catch((cause: unknown) => cause)
    expect(failure).toBeInstanceOf(GitError)
    expect((failure as GitError).message.length).toBeGreaterThan(0)
  })
})

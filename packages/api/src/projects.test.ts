import { describe, expect, it } from "vitest"
import { repoIdentityKey } from "./projects.js"

describe("repoIdentityKey", () => {
  it("collapses every spelling of one GitHub remote to the same key", () => {
    const expected = "github.com/acme/widget"
    for (const url of [
      "git@github.com:acme/widget.git",
      "git@github.com:Acme/Widget",
      "ssh://git@github.com/acme/widget.git",
      "ssh://git@github.com:22/acme/widget.git",
      "https://github.com/acme/widget",
      "https://github.com/acme/widget/",
      "https://github.com/acme/widget.git",
      "https://user:token@github.com/acme/widget.git",
      "HTTPS://GitHub.com/acme/widget.GIT",
      "git://github.com/acme/widget.git",
      "  git@github.com:acme/widget.git\n"
    ]) {
      expect(repoIdentityKey(url), url).toBe(expected)
    }
  })

  it("keeps distinct repositories and hosts apart", () => {
    expect(repoIdentityKey("git@github.com:acme/widget.git")).not.toBe(
      repoIdentityKey("git@github.com:acme/widget-docs.git")
    )
    expect(repoIdentityKey("https://github.com/acme/widget")).not.toBe(
      repoIdentityKey("https://gitlab.com/acme/widget")
    )
    expect(repoIdentityKey("https://github.com/acme/widget")).not.toBe(
      repoIdentityKey("https://github.com/fork/widget")
    )
  })

  it("handles self-hosted forges with nested groups and a leading tilde", () => {
    expect(repoIdentityKey("git@gitlab.example.com:group/sub/repo.git")).toBe(
      "gitlab.example.com/group/sub/repo"
    )
    expect(repoIdentityKey("ssh://git@code.example.com:2222/~user/repo.git")).toBe(
      "code.example.com/user/repo"
    )
  })

  it("refuses remotes without a network host", () => {
    expect(repoIdentityKey("")).toBeUndefined()
    expect(repoIdentityKey("   ")).toBeUndefined()
    expect(repoIdentityKey("/Users/me/src/widget")).toBeUndefined()
    expect(repoIdentityKey("../widget")).toBeUndefined()
    expect(repoIdentityKey("file:///Users/me/src/widget")).toBeUndefined()
    expect(repoIdentityKey("https://")).toBeUndefined()
    expect(repoIdentityKey("git@github.com:")).toBeUndefined()
    expect(repoIdentityKey("git@github.com:.git")).toBeUndefined()
  })
})

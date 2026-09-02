import { parseSkillSource, SkillsError } from "./skills-manager.js"
import { afterEach, describe, expect, it } from "vitest"
import { cleanupSkillsTests } from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

describe("parseSkillSource", () => {
  it("parses owner/repo shorthand with refs and subpaths", () => {
    expect(parseSkillSource("vercel-labs/skills")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("vercel-labs/skills#main")).toEqual({
      kind: "git",
      ref: "main",
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("vercel-labs/skills/skills/find-skills")).toEqual({
      kind: "git",
      ref: undefined,
      subpath: "skills/find-skills",
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("github:vercel-labs/skills")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
  })

  it("parses github.com URLs including tree paths", () => {
    expect(parseSkillSource("https://github.com/vercel-labs/skills")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("https://github.com/vercel-labs/skills.git")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(
      parseSkillSource("https://github.com/vercel-labs/skills/tree/main/skills/find-skills")
    ).toEqual({
      kind: "git",
      ref: "main",
      subpath: "skills/find-skills",
      url: "https://github.com/vercel-labs/skills.git"
    })
    // An explicit #ref wins over the /tree/ segment.
    expect(parseSkillSource("https://github.com/o/r/tree/main/path#pinned")).toEqual({
      kind: "git",
      ref: "pinned",
      subpath: "path",
      url: "https://github.com/o/r.git"
    })
    // A tree URL for the repo root has a ref but no subpath.
    expect(parseSkillSource("https://github.com/o/r/tree/main")).toEqual({
      kind: "git",
      ref: "main",
      url: "https://github.com/o/r.git"
    })
    expect(parseSkillSource("https://github.com/o/r/some/path")).toEqual({
      kind: "git",
      ref: undefined,
      subpath: "some/path",
      url: "https://github.com/o/r.git"
    })
  })

  it("passes through local filesystem paths", () => {
    expect(parseSkillSource("/tmp/my-skills-repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "/tmp/my-skills-repo"
    })
    expect(parseSkillSource("./relative/repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "./relative/repo"
    })
    expect(parseSkillSource("../up/repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "../up/repo"
    })
    expect(parseSkillSource("/tmp/repo#main")).toEqual({
      kind: "git",
      ref: "main",
      url: "/tmp/repo"
    })
  })

  it("passes through git and non-GitHub URLs", () => {
    expect(parseSkillSource("git@github.com:o/r.git")).toEqual({
      kind: "git",
      ref: undefined,
      url: "git@github.com:o/r.git"
    })
    expect(parseSkillSource("ssh://git@host/o/r.git#v2")).toEqual({
      kind: "git",
      ref: "v2",
      url: "ssh://git@host/o/r.git"
    })
    expect(parseSkillSource("https://gitlab.com/o/r.git#dev")).toEqual({
      kind: "git",
      ref: "dev",
      url: "https://gitlab.com/o/r.git"
    })
  })

  it("parses gitlab sources including subgroups and tree paths", () => {
    expect(parseSkillSource("gitlab:o/r")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://gitlab.com/o/r.git"
    })
    expect(parseSkillSource("https://gitlab.com/group/sub/repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://gitlab.com/group/sub/repo.git"
    })
    expect(parseSkillSource("https://gitlab.com/o/r/-/tree/main/skills/deploy")).toEqual({
      kind: "git",
      ref: "main",
      subpath: "skills/deploy",
      url: "https://gitlab.com/o/r.git"
    })
    expect(() => parseSkillSource("https://gitlab.com/only-owner")).toThrow("Not a repository URL")
    expect(parseSkillSource("https://gitlab.com/o/r/-/tree/main")).toEqual({
      kind: "git",
      ref: "main",
      url: "https://gitlab.com/o/r.git"
    })
    // An explicit #ref wins over the /-/tree/ segment.
    expect(parseSkillSource("https://gitlab.com/o/r/-/tree/main/path#pinned")).toEqual({
      kind: "git",
      ref: "pinned",
      subpath: "path",
      url: "https://gitlab.com/o/r.git"
    })
  })

  it("routes non-repository HTTPS URLs to well-known discovery", () => {
    expect(parseSkillSource("https://skills.example.com")).toEqual({
      kind: "wellKnown",
      url: "https://skills.example.com"
    })
    expect(parseSkillSource("https://example.com/docs/skills")).toEqual({
      kind: "wellKnown",
      url: "https://example.com/docs/skills"
    })
    // Explicit git remotes still clone.
    expect(parseSkillSource("https://myhost.dev/team/repo.git#dev")).toEqual({
      kind: "git",
      ref: "dev",
      url: "https://myhost.dev/team/repo.git"
    })
  })

  it("rejects empty and unrecognizable sources", () => {
    expect(() => parseSkillSource("  ")).toThrow(SkillsError)
    expect(() => parseSkillSource("just-a-name")).toThrow("Unrecognized skill source")
    expect(() => parseSkillSource("https://github.com/only-owner")).toThrow("Not a repository URL")
    // A trailing # is treated as no ref at all.
    expect(parseSkillSource("o/r#")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/o/r.git"
    })
  })
})

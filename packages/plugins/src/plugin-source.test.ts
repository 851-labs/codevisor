import { execFileSync } from "node:child_process"
import { mkdirSync, readdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { clonePluginSource, parsePluginSource } from "./plugin-source.js"
import { makeDir } from "./test-support.js"

describe("parsePluginSource", () => {
  it("rejects empty sources", () => {
    expect(() => parsePluginSource("")).toThrow(/plugin source is required/)
    expect(() => parsePluginSource("   ")).toThrow(/plugin source is required/)
  })

  it("parses owner/repo shorthand with refs and subpaths", () => {
    expect(parsePluginSource("acme/tools")).toEqual({
      owner: "acme",
      ref: undefined,
      url: "https://github.com/acme/tools.git"
    })
    expect(parsePluginSource("acme/tools#v1.2.0")).toEqual({
      owner: "acme",
      ref: "v1.2.0",
      url: "https://github.com/acme/tools.git"
    })
    expect(parsePluginSource("acme/tools/plugins/diff#main")).toEqual({
      owner: "acme",
      ref: "main",
      subpath: "plugins/diff",
      url: "https://github.com/acme/tools.git"
    })
    // A trailing "#" means no ref, same as skills.
    expect(parsePluginSource("acme/tools#").ref).toBeUndefined()
    expect(() => parsePluginSource("just-a-name")).toThrow(/Unrecognized plugin source/)
  })

  it("strips the github: prefix", () => {
    expect(parsePluginSource("github:acme/tools")).toEqual({
      owner: "acme",
      ref: undefined,
      url: "https://github.com/acme/tools.git"
    })
  })

  it("passes git and ssh remotes through verbatim", () => {
    expect(parsePluginSource("git@github.com:acme/tools.git#dev")).toEqual({
      ref: "dev",
      url: "git@github.com:acme/tools.git"
    })
    expect(parsePluginSource("ssh://git@example.com/acme/tools.git")).toEqual({
      ref: undefined,
      url: "ssh://git@example.com/acme/tools.git"
    })
  })

  it("treats filesystem paths and file URLs as local clone sources", () => {
    expect(parsePluginSource("/tmp/my-plugin")).toEqual({
      local: true,
      ref: undefined,
      url: "/tmp/my-plugin"
    })
    expect(parsePluginSource("./my-plugin#work")).toEqual({
      local: true,
      ref: "work",
      url: "./my-plugin"
    })
    expect(parsePluginSource("../my-plugin")).toEqual({
      local: true,
      ref: undefined,
      url: "../my-plugin"
    })
    expect(parsePluginSource("file:///tmp/my-plugin")).toEqual({
      local: true,
      ref: undefined,
      url: "file:///tmp/my-plugin"
    })
  })

  it("parses github.com URLs including tree paths", () => {
    expect(parsePluginSource("https://github.com/acme/tools")).toEqual({
      owner: "acme",
      ref: undefined,
      url: "https://github.com/acme/tools.git"
    })
    expect(parsePluginSource("https://www.github.com/acme/tools.git#v2")).toEqual({
      owner: "acme",
      ref: "v2",
      url: "https://github.com/acme/tools.git"
    })
    expect(parsePluginSource("https://github.com/acme/tools/tree/main/plugins/diff")).toEqual({
      owner: "acme",
      ref: "main",
      subpath: "plugins/diff",
      url: "https://github.com/acme/tools.git"
    })
    // A #ref wins over the tree ref; a tree URL without a deeper path has no
    // subpath.
    expect(parsePluginSource("https://github.com/acme/tools/tree/main#pinned")).toEqual({
      owner: "acme",
      ref: "pinned",
      url: "https://github.com/acme/tools.git"
    })
    // Non-tree URL path segments become the subpath.
    expect(parsePluginSource("https://github.com/acme/tools/plugins/diff")).toEqual({
      owner: "acme",
      ref: undefined,
      subpath: "plugins/diff",
      url: "https://github.com/acme/tools.git"
    })
    expect(() => parsePluginSource("https://github.com/acme")).toThrow(/Not a repository URL/)
  })

  it("hands non-github https URLs to git verbatim", () => {
    expect(parsePluginSource("https://git.example.com/acme/tools.git#main")).toEqual({
      ref: "main",
      url: "https://git.example.com/acme/tools.git"
    })
  })
})

const initGitRepo = (files: Record<string, string>): string => {
  const repo = makeDir("codevisor-plugin-repo-")
  for (const [name, content] of Object.entries(files)) {
    mkdirSync(join(repo, name, ".."), { recursive: true })
    writeFileSync(join(repo, name), content)
  }
  const git = (...args: Array<string>): void => {
    execFileSync("git", ["-C", repo, ...args], { stdio: "ignore" })
  }
  git("init", "--quiet", "--initial-branch", "main")
  git("-c", "user.email=t@example.com", "-c", "user.name=t", "add", ".")
  git("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--quiet", "-m", "initial")
  return repo
}

describe("clonePluginSource", () => {
  it("shallow-clones a local repository, optionally pinned to a ref", async () => {
    const repo = initGitRepo({ "codevisor-plugin.json": "{}" })
    const destination = join(makeDir("codevisor-plugin-clone-"), "checkout")
    await clonePluginSource(repo, "main", destination)
    expect(readdirSync(destination)).toContain("codevisor-plugin.json")
  })

  it("rejects with git's stderr when the clone fails", async () => {
    const destination = join(makeDir("codevisor-plugin-clone-"), "checkout")
    await expect(
      clonePluginSource("/nonexistent/definitely-not-a-repo", undefined, destination)
    ).rejects.toThrow(/repository|not exist|No such file/i)
  })
})

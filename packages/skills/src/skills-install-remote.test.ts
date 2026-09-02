import { makeAgentRuntime } from "@codevisor/agent-runtime"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { execSync } from "node:child_process"
import { makeSkillsManager } from "./skills-manager.js"
import type { SkillsManager } from "./skills-manager.js"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupSkillsTests,
  makeHome,
  writeSkill,
  manager,
  globalSkill,
  installState
} from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

describe("importRemote", () => {
  const managerWithClone = (
    home: string,
    clone: (url: string, ref: string | undefined, destination: string) => Promise<void>
  ): SkillsManager =>
    makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      overrides: { clone }
    })

  it("imports every skill found in a cloned repo", async () => {
    const home = makeHome()
    const calls: Array<[string, string | undefined]> = []
    const skills = managerWithClone(home, async (url, ref, destination) => {
      calls.push([url, ref])
      writeSkill(join(destination, "skills/deploy"), { name: "Deploy" })
      writeSkill(join(destination, "skills/review"), { name: "Review" })
      // Stray files, ignored locations, and too-deep nesting never import.
      writeFileSync(join(destination, "README.md"), "docs")
      mkdirSync(join(destination, "node_modules/ignored"), { recursive: true })
      writeFileSync(join(destination, "node_modules/ignored/SKILL.md"), "nope")
      writeSkill(join(destination, ".git/hooks"), { name: "Git Internals" })
      writeSkill(join(destination, "a/b/c/d/too-deep"), { name: "Too Deep" })
    })
    const scan = await skills.importRemote({ source: "vercel-labs/skills#main" })
    expect(calls).toEqual([["https://github.com/vercel-labs/skills.git", "main"]])
    expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual(["deploy", "review"])
  })

  it("scopes discovery to the requested subpath", async () => {
    const home = makeHome()
    const skills = managerWithClone(home, async (_url, _ref, destination) => {
      writeSkill(join(destination, "skills/deploy"), { name: "Deploy" })
      writeSkill(join(destination, "skills/review"), { name: "Review" })
    })
    const scan = await skills.importRemote({ source: "o/r/skills/deploy" })
    expect(scan.global.map((skill) => skill.directoryName)).toEqual(["deploy"])
  })

  it("rejects subpath traversal, empty repos, and clone failures", async () => {
    const home = makeHome()
    await expect(
      managerWithClone(home, async () => {}).importRemote({ source: "o/r/../../etc" })
    ).rejects.toMatchObject({ code: "invalid" })
    await expect(
      managerWithClone(home, async () => {}).importRemote({ source: "o/empty" })
    ).rejects.toMatchObject({ code: "invalid" })
    await expect(
      managerWithClone(home, async () => {
        throw new Error("repository not found")
      }).importRemote({ source: "o/missing" })
    ).rejects.toMatchObject({ code: "invalid" })
    // A subpath that does not exist in the clone reads as no skills found.
    await expect(
      managerWithClone(home, async () => {}).importRemote({ source: "o/r/absent/dir" })
    ).rejects.toMatchObject({ code: "invalid" })
    // Non-Error clone failures with a pinned ref still produce a useful message.
    await expect(
      managerWithClone(home, async () => {
        throw "socket hangup"
      }).importRemote({ source: "o/missing#dev" })
    ).rejects.toThrow("(dev): socket hangup")
  })

  it("skips existing skills and fails only when nothing was imported", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    const clone = async (_url: string, _ref: string | undefined, destination: string) => {
      writeSkill(join(destination, "deploy"), { body: "different", name: "Deploy" })
      writeSkill(join(destination, "review"), { name: "Review" })
    }
    const scan = await managerWithClone(home, clone).importRemote({ source: "o/r" })
    expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual(["deploy", "review"])
    // Second run: everything conflicts now.
    await expect(
      managerWithClone(home, clone).importRemote({ source: "o/r" })
    ).rejects.toMatchObject({ code: "conflict" })
  })

  it("surfaces default-clone failures as invalid sources", async () => {
    const home = makeHome()
    await expect(
      manager(home).importRemote({ source: join(home, "does-not-exist") })
    ).rejects.toMatchObject({ code: "invalid" })
  })

  it("clones for real from a local git repository", async () => {
    const home = makeHome()
    const upstream = join(home, "upstream")
    writeSkill(join(upstream, "my-skill"), { description: "From git", name: "My Skill" })
    execSync(
      `git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm skill`,
      { cwd: upstream }
    )
    // Pin the ref too, exercising the default clone's --branch path.
    const scan = await manager(home).importRemote({ source: `${upstream}#main` })
    expect(globalSkill(scan, "my-skill").description).toBe("From git")
  })
})

describe("well-known skill sources", () => {
  const startSkillSite = async (
    handler: (path: string) => { status: number; body: Buffer | string } | undefined
  ) => {
    const { createServer } = await import("node:http")
    const server = createServer((request, response) => {
      const result = handler(request.url ?? "/")
      if (result === undefined) {
        response.writeHead(404)
        response.end()
        return
      }
      response.writeHead(result.status)
      response.end(result.body)
    })
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    const address = server.address()
    if (address === null || typeof address === "string") throw new Error("missing port")
    return {
      close: () => new Promise<void>((resolve) => server.close(() => resolve())),
      url: `http://127.0.0.1:${address.port}`
    }
  }

  it("imports legacy file-list skills from the well-known index", async () => {
    const home = makeHome()
    const site = await startSkillSite((path) => {
      if (path === "/.well-known/agent-skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            skills: [
              {
                name: "deploy",
                description: "Deploy checklist",
                files: ["SKILL.md", "refs/notes.md"]
              },
              { name: "broken", description: "missing files", files: ["SKILL.md"] }
            ]
          })
        }
      }
      if (path === "/.well-known/agent-skills/deploy/SKILL.md") {
        return {
          status: 200,
          body: "---\nname: Deploy\ndescription: Deploy checklist\n---\nSteps."
        }
      }
      if (path === "/.well-known/agent-skills/deploy/refs/notes.md") {
        return { status: 200, body: "notes" }
      }
      // The "broken" skill's file 404s — that entry must be skipped.
      return undefined
    })
    try {
      const scan = await manager(home).importRemote({ source: site.url })
      expect(globalSkill(scan, "deploy").description).toBe("Deploy checklist")
      expect(readFileSync(join(home, ".agents/skills/deploy/refs/notes.md"), "utf8")).toBe("notes")
      expect(scan.global.map((skill) => skill.directoryName)).toEqual(["deploy"])
      // Auto-install applied to well-known imports too.
      expect(installState(scan, "deploy", "claude-code")).toBe("linked")
    } finally {
      await site.close()
    }
  })

  it("imports v0.2.0 skill-md and tar.gz archive artifacts with digest checks", async () => {
    const home = makeHome()
    const { execSync } = await import("node:child_process")
    const { createHash } = await import("node:crypto")
    // Build a tgz artifact containing an archived skill.
    const artifactSource = join(home, "artifact-src")
    writeSkill(join(artifactSource, "archived"), { description: "From archive", name: "Archived" })
    execSync(`tar -czf ${join(home, "archived.tgz")} -C ${artifactSource} archived`)
    const archiveBytes = readFileSync(join(home, "archived.tgz"))
    const archiveDigest = `sha256:${createHash("sha256").update(archiveBytes).digest("hex")}`
    const singleBody = "---\nname: Single\ndescription: Just one file\n---\nBody."
    const singleDigest = `sha256:${createHash("sha256").update(Buffer.from(singleBody)).digest("hex")}`

    const site = await startSkillSite((path) => {
      if (path === "/.well-known/agent-skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            $schema: "v2",
            skills: [
              {
                name: "single",
                type: "skill-md",
                description: "one",
                url: "single.md",
                digest: singleDigest
              },
              {
                name: "archived",
                type: "archive",
                description: "arch",
                url: "archived.tgz",
                digest: archiveDigest
              },
              {
                name: "tampered",
                type: "archive",
                description: "bad",
                url: "archived.tgz",
                digest: "sha256:deadbeef"
              },
              {
                name: "",
                type: "skill-md",
                description: "nameless",
                url: "single.md",
                digest: singleDigest
              },
              { description: "no url either" }
            ]
          })
        }
      }
      if (path === "/.well-known/agent-skills/single.md") return { status: 200, body: singleBody }
      if (path === "/.well-known/agent-skills/archived.tgz")
        return { status: 200, body: archiveBytes }
      return undefined
    })
    try {
      const scan = await manager(home).importRemote({ source: site.url })
      expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual(["archived", "single"])
      expect(globalSkill(scan, "archived").description).toBe("From archive")
    } finally {
      await site.close()
    }
  })

  it("falls back to the origin and legacy well-known paths", async () => {
    const home = makeHome()
    const site = await startSkillSite((path) => {
      if (path === "/.well-known/skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            skills: [{ name: "deploy", description: "d", files: ["SKILL.md"] }]
          })
        }
      }
      if (path === "/.well-known/skills/deploy/SKILL.md") {
        return { status: 200, body: "---\nname: Deploy\ndescription: d\n---\nx" }
      }
      return undefined
    })
    try {
      // A deep page URL still resolves through the origin's legacy path.
      const scan = await manager(home).importRemote({ source: `${site.url}/docs/page/` })
      expect(globalSkill(scan, "deploy")).toBeDefined()
    } finally {
      await site.close()
    }
  })

  it("tolerates malformed indexes, bad entries, and broken archives", async () => {
    const home = makeHome()
    const { execSync } = await import("node:child_process")
    const { createHash } = await import("node:crypto")
    // A zip artifact, and a corrupt "gzip" artifact (valid magic, garbage body).
    const zipSource = join(home, "zip-src")
    writeSkill(join(zipSource, "zipped"), { description: "From zip", name: "Zipped" })
    execSync(`cd ${zipSource} && zip -qr ${join(home, "zipped.zip")} zipped`)
    const zipBytes = readFileSync(join(home, "zipped.zip"))
    const zipDigest = `sha256:${createHash("sha256").update(zipBytes).digest("hex")}`
    const corruptGzip = Buffer.concat([Buffer.from([0x1f, 0x8b]), Buffer.from("garbage")])
    const corruptDigest = `sha256:${createHash("sha256").update(corruptGzip).digest("hex")}`
    const plainBytes = Buffer.from("not an archive")
    const plainDigest = `sha256:${createHash("sha256").update(plainBytes).digest("hex")}`

    const site = await startSkillSite((path) => {
      // The path-relative candidate serves invalid JSON; the origin's
      // agent-skills index serves a non-array shape; the legacy origin
      // index finally works — exercising the whole candidate chain.
      if (path === "/docs/.well-known/agent-skills/index.json") {
        return { status: 200, body: "{ not json" }
      }
      if (path === "/.well-known/agent-skills/index.json") {
        return { status: 200, body: JSON.stringify({ skills: "nope" }) }
      }
      if (path === "/.well-known/skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            skills: [
              {
                name: "zipped",
                type: "archive",
                description: "z",
                url: "zipped.zip",
                digest: zipDigest
              },
              {
                name: "corrupt",
                type: "archive",
                description: "c",
                url: "corrupt.tgz",
                digest: corruptDigest
              },
              {
                name: "notarchive",
                type: "archive",
                description: "p",
                url: "plain.bin",
                digest: plainDigest
              },
              {
                name: "gone",
                type: "archive",
                description: "g",
                url: "missing.tgz",
                digest: "sha256:x"
              },
              { name: "nourl", description: "entry without url or files" },
              { name: "oddfiles", description: "odd", files: ["SKILL.md", 42, "../evil.md"] },
              { name: "nodigest", type: "skill-md", description: "nd", url: "nodigest.md" },
              "not-an-object"
            ]
          })
        }
      }
      if (path === "/.well-known/skills/zipped.zip") return { status: 200, body: zipBytes }
      if (path === "/.well-known/skills/corrupt.tgz") return { status: 200, body: corruptGzip }
      if (path === "/.well-known/skills/plain.bin") return { status: 200, body: plainBytes }
      if (path === "/.well-known/skills/nodigest.md") {
        return { status: 200, body: "---\nname: No Digest\ndescription: nd\n---\nx" }
      }
      if (path === "/.well-known/skills/oddfiles/SKILL.md") {
        return { status: 200, body: "---\nname: Odd Files\ndescription: odd\n---\nx" }
      }
      return undefined
    })
    try {
      const scan = await manager(home).importRemote({ source: `${site.url}/docs` })
      expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual([
        "no-digest",
        "odd-files",
        "zipped"
      ])
      expect(globalSkill(scan, "zipped").description).toBe("From zip")
    } finally {
      await site.close()
    }
  })

  it("fails cleanly when a site publishes nothing", async () => {
    const home = makeHome()
    const site = await startSkillSite(() => undefined)
    try {
      await expect(manager(home).importRemote({ source: site.url })).rejects.toMatchObject({
        code: "invalid"
      })
    } finally {
      await site.close()
    }
  })
})

describe("remote discovery and selective import", () => {
  const cloneWithTwoSkills = async (
    _url: string,
    _ref: string | undefined,
    destination: string
  ) => {
    writeSkill(join(destination, "skills/deploy"), { description: "Deploys", name: "Deploy" })
    writeSkill(join(destination, "skills/review"), { description: "Reviews", name: "Review" })
    // Broken frontmatter: named by its directory, no description.
    mkdirSync(join(destination, "skills/plain"), { recursive: true })
    writeFileSync(join(destination, "skills/plain/SKILL.md"), "---\n- broken\n---\n")
  }

  it("lists a source's skills with existence flags without importing", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    const skills = makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      overrides: { clone: cloneWithTwoSkills }
    })
    const discovered = await skills.discoverRemote({ source: "o/r" })
    expect(discovered.skills).toEqual([
      { alreadyExists: true, description: "Deploys", directoryName: "deploy", name: "Deploy" },
      { alreadyExists: false, directoryName: "plain", name: "plain" },
      { alreadyExists: false, description: "Reviews", directoryName: "review", name: "Review" }
    ])
    // Nothing was imported.
    expect(existsSync(join(home, ".agents/skills/review"))).toBe(false)
  })

  it("imports only the selected skills", async () => {
    const home = makeHome()
    const skills = makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      overrides: { clone: cloneWithTwoSkills }
    })
    const scan = await skills.importRemote({ skillNames: ["Review", "plain"], source: "o/r" })
    expect(scan.global.map((skill) => skill.directoryName)).toEqual(["plain", "review"])
    await expect(
      skills.importRemote({ skillNames: ["ghost"], source: "o/r" })
    ).rejects.toMatchObject({ code: "notFound" })
  })
})

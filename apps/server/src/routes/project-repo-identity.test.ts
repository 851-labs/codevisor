import { execFile } from "node:child_process"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"
import { jsonRequest, makeServices, run, start, tempDirs } from "../test-support.js"
import { backfillProjectRepoUrls, resetRepoUrlDiscoveryCache } from "./project-repo-identity.js"
import { makeEventFanout } from "../server-context.js"

const execFileAsync = promisify(execFile)

/// A project's git remote is its cross-machine identity: observed from the
/// folder, normalized into a repo key, backfilled for older rows — and never
/// mistaken for the repository a scratch folder happens to be nested in.
describe("project repo identity", () => {
  it("records a folder project's git remote at creation and derives its repo key", async () => {
    const { server } = await start()
    const repo = mkdtempSync(join(tmpdir(), "codevisor-remote-"))
    tempDirs.push(repo)
    await execFileAsync("git", ["init"], { cwd: repo })
    await execFileAsync("git", ["remote", "add", "origin", "git@github.com:Acme/Widget.git"], {
      cwd: repo
    })

    const created = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: repo, id: "remote-project" }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    expect(created.body).toMatchObject({
      repoUrl: "git@github.com:Acme/Widget.git",
      repoKey: "github.com/acme/widget"
    })

    // An explicitly supplied remote is kept as-is, with no discovery.
    const explicitFolder = mkdtempSync(join(tmpdir(), "codevisor-explicit-"))
    tempDirs.push(explicitFolder)
    const explicit = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({
        folderPath: explicitFolder,
        id: "explicit-project",
        repoUrl: "https://github.com/acme/other.git"
      }),
      method: "POST"
    })
    expect(explicit.status).toBe(201)
    expect((explicit.body as { readonly repoKey?: string }).repoKey).toBe("github.com/acme/other")

    // A plain folder (no repository) stays unlinked.
    const plainFolder = mkdtempSync(join(tmpdir(), "codevisor-plain-"))
    tempDirs.push(plainFolder)
    const plain = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
      method: "POST"
    })
    expect(plain.status).toBe(201)
    expect((plain.body as { readonly repoUrl?: string }).repoUrl).toBeUndefined()
    expect((plain.body as { readonly repoKey?: string }).repoKey).toBeUndefined()

    // A remote added AFTER the project was links up on the next list.
    await execFileAsync("git", ["init"], { cwd: plainFolder })
    await execFileAsync(
      "git",
      ["remote", "add", "origin", "https://github.com/acme/widget-docs.git"],
      { cwd: plainFolder }
    )
    resetRepoUrlDiscoveryCache()
    const listed = await jsonRequest(server, "/v1/projects", { method: "GET" })
    expect(listed.status).toBe(200)
    const byId = new Map(
      (listed.body as ReadonlyArray<{ readonly id: string; readonly repoKey?: string }>).map(
        (project) => [project.id, project.repoKey]
      )
    )
    expect(byId.get("remote-project")).toBe("github.com/acme/widget")
    expect(byId.get("plain-project")).toBe("github.com/acme/widget-docs")

    // A second list inside the memo window answers from the cache — no
    // fresh git spawn per folder per navigation refresh.
    const relisted = await jsonRequest(server, "/v1/projects", { method: "GET" })
    expect(relisted.status).toBe(200)
    expect(
      (relisted.body as ReadonlyArray<{ readonly id: string; readonly repoKey?: string }>).find(
        (project) => project.id === "plain-project"
      )?.repoKey
    ).toBe("github.com/acme/widget-docs")
  })

  it("backfills remotes for projects recorded before they were tracked", async () => {
    const { services } = await makeServices("server-a")
    const repo = mkdtempSync(join(tmpdir(), "codevisor-backfill-"))
    tempDirs.push(repo)
    await execFileAsync("git", ["init"], { cwd: repo })
    await execFileAsync("git", ["remote", "add", "origin", "ssh://git@github.com/acme/widget"], {
      cwd: repo
    })
    const missingFolder = join(repo, "gone")
    // Legacy rows: created straight in the database with no repoUrl, the
    // way every release before remote tracking left them.
    await run(services.db.createProject({ folderPath: repo, id: "legacy-linked" }))
    await run(services.db.createProject({ folderPath: missingFolder, id: "legacy-missing" }))
    // A clone-from-git project keeps its recorded URL even though the
    // folder no longer exists on disk.
    await run(
      services.db.createProject({
        folderPath: join(repo, "cloned"),
        id: "legacy-cloned",
        repoUrl: "https://github.com/acme/cloned.git"
      })
    )

    const fanout = await run(makeEventFanout)
    const updates: Array<string> = []
    fanout.subscribe((event) => {
      if (event.kind === "project.updated") updates.push(event.subjectId)
    })
    resetRepoUrlDiscoveryCache()
    await backfillProjectRepoUrls(services.db, "server-a", fanout)

    const projects = new Map(
      (await run(services.db.listProjects)).map((project) => [project.id, project.repoUrl])
    )
    expect(projects.get("legacy-linked")).toBe("ssh://git@github.com/acme/widget")
    expect(projects.get("legacy-missing")).toBeUndefined()
    expect(projects.get("legacy-cloned")).toBe("https://github.com/acme/cloned.git")
    expect(updates).toEqual(["legacy-linked"])

    // Idempotent: a second sweep finds nothing to change and stays quiet.
    resetRepoUrlDiscoveryCache()
    await backfillProjectRepoUrls(services.db, "server-a", fanout)
    expect(updates).toEqual(["legacy-linked"])
  })

  it("never treats a scratch folder as a repository, even nested inside a checkout", async () => {
    // A development layout keeps the worktrees root inside the app's own
    // checkout, so every scratch folder is inside a git work tree.
    const checkout = mkdtempSync(join(tmpdir(), "codevisor-checkout-"))
    tempDirs.push(checkout)
    await execFileAsync("git", ["init"], { cwd: checkout })
    await execFileAsync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
      { cwd: checkout }
    )
    process.env["CODEVISOR_WORKTREES_ROOT"] = join(checkout, "tmp", "codevisor")
    try {
      const { server } = await start()
      const created = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({ id: "nested-scratch" }),
        method: "POST"
      })
      expect(created.status).toBe(201)
      const scratch = created.body as {
        readonly isScratch?: boolean
        readonly repoKey?: string
        readonly locations: ReadonlyArray<{ readonly isGitRepository?: boolean }>
      }
      expect(scratch.isScratch).toBe(true)
      expect(scratch.locations[0]?.isGitRepository).toBe(false)
      expect(scratch.repoKey).toBeUndefined()

      const worktree = await jsonRequest(server, "/v1/projects/nested-scratch/worktrees", {
        body: JSON.stringify({ name: "oops" }),
        method: "POST"
      })
      expect(worktree.status).toBe(422)
      expect(
        (await execFileAsync("git", ["worktree", "list"], { cwd: checkout })).stdout.trim()
      ).not.toContain("oops")
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })
})

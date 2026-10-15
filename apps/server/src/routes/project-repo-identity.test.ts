import { execFile } from "node:child_process"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, Project } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { makeEventFanout } from "../server-context.js"
import { jsonRequest, makeServices, run, start, tempDirs } from "../test-support.js"
import {
  backfillProjectRepoUrls,
  reconcileProjectRepoUrls,
  resetRepoUrlDiscoveryCache
} from "./project-repo-identity.js"

const execFileAsync = promisify(execFile)
const decodeProject = decode(Project)
const decodeProjects = decode(Schema.Array(Project))

describe("project repo identity", () => {
  it("refreshes persisted navigation when a plain folder becomes a repository", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-navigation-git-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const before = await run(services.db.getNavigationSnapshot)
    expect(before.projects[0]?.locations[0]?.isGitRepository).toBe(false)
    await execFileAsync("git", ["init"], { cwd: folder })
    const reconciled = await reconcileProjectRepoUrls(services.db, "server-a", [
      {
        ...project,
        locations: [
          ...project.locations,
          { ...project.locations[0]!, id: "remote-location", serverId: "remote" }
        ]
      }
    ])
    expect(reconciled[0]!.locations[1]!.id).toBe("remote-location")
    const fanout = await run(makeEventFanout)
    await Promise.all([
      backfillProjectRepoUrls(services.db, "server-a", fanout),
      backfillProjectRepoUrls(services.db, "server-a", fanout)
    ])
    const after = await run(services.db.getNavigationSnapshot)
    expect(after.projects[0]?.locations[0]?.isGitRepository).toBe(true)
    const replay = await run(services.db.readSyncBatch(before.eventCursor))
    expect(
      replay.events.find((event) => event.kind === "navigation.changed")?.payload
    ).toMatchObject({
      projects: [{ id: project.id, locations: [{ isGitRepository: true }] }]
    })
  })

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
    expect(decodeProject(explicit.body).repoKey).toBe("github.com/acme/other")

    const plainFolder = mkdtempSync(join(tmpdir(), "codevisor-plain-"))
    tempDirs.push(plainFolder)
    const plain = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
      method: "POST"
    })
    expect(plain.status).toBe(201)
    const plainProject = decodeProject(plain.body)
    expect(plainProject.repoUrl).toBeUndefined()
    expect(plainProject.repoKey).toBeUndefined()

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
      decodeProjects(listed.body).map((project) => [project.id, project.repoKey])
    )
    expect(byId.get("remote-project")).toBe("github.com/acme/widget")
    expect(byId.get("plain-project")).toBe("github.com/acme/widget-docs")

    const relisted = await jsonRequest(server, "/v1/projects", { method: "GET" })
    expect(relisted.status).toBe(200)
    expect(
      decodeProjects(relisted.body).find((project) => project.id === "plain-project")?.repoKey
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
    await run(services.db.createProject({ folderPath: repo, id: "legacy-linked" }))
    await run(services.db.createProject({ folderPath: missingFolder, id: "legacy-missing" }))
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

    resetRepoUrlDiscoveryCache()
    await backfillProjectRepoUrls(services.db, "server-a", fanout)
    expect(updates).toEqual(["legacy-linked"])
  })

  it("never treats a scratch folder as a repository, even nested inside a checkout", async () => {
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
      const scratch = decodeProject(created.body)
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

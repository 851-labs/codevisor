import type { AgentSessionSummary } from "@codevisor/api"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { recommendProjectsFromSessions } from "./project-recommendations.js"

const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true })
})

describe("project recommendations", () => {
  it("groups existing folders and ranks them by their latest activity", () => {
    const root = makeRoot()
    const alpha = join(root, "alpha")
    const beta = join(root, "beta")
    mkdirSync(alpha)
    mkdirSync(beta)

    const recommendations = recommendProjectsFromSessions(
      [
        session("one", alpha, "2026-01-01T00:00:00Z"),
        session("two", alpha, "2026-01-02T00:00:00Z"),
        session("three", beta, "2026-02-01T00:00:00Z"),
        session("missing", join(root, "gone"), "2026-03-01T00:00:00Z")
      ],
      {
        managedWorktreesRoot: join(root, "managed"),
        temporaryDirectory: join(root, "temporary")
      }
    )

    expect(recommendations).toEqual([
      {
        path: beta,
        name: "beta",
        sessionCount: 1,
        lastActivity: "2026-02-01T00:00:00Z"
      },
      {
        path: alpha,
        name: "alpha",
        sessionCount: 2,
        lastActivity: "2026-01-02T00:00:00Z"
      }
    ])
  })

  it("orders dated, frequent, and alphabetically tied recommendations", () => {
    const root = makeRoot()
    const alpha = join(root, "alpha")
    const beta = join(root, "beta")
    const recent = join(root, "recent")
    for (const path of [alpha, beta, recent]) mkdirSync(path)
    const options = {
      managedWorktreesRoot: join(root, "managed"),
      temporaryDirectory: join(root, "temporary")
    }

    const datedFirst = recommendProjectsFromSessions(
      [session("recent", recent, "2026-02-01T00:00:00Z"), session("alpha", alpha)],
      options
    )
    const datedLast = recommendProjectsFromSessions(
      [session("alpha", alpha), session("recent", recent, "2026-02-01T00:00:00Z")],
      options
    )
    const frequent = recommendProjectsFromSessions(
      [session("alpha-one", alpha), session("beta-one", beta), session("beta-two", beta)],
      options
    )

    expect(datedFirst.map((entry) => entry.name)).toEqual(["recent", "alpha"])
    expect(datedLast.map((entry) => entry.name)).toEqual(["recent", "alpha"])
    expect(frequent.map((entry) => entry.name)).toEqual(["beta", "alpha"])
  })

  it("keeps the newest valid activity when later session metadata is stale", () => {
    const root = makeRoot()
    const project = join(root, "project")
    mkdirSync(project)

    expect(
      recommendProjectsFromSessions(
        [
          session("newest", project, "2026-02-01T00:00:00Z"),
          session("older", project, "2026-01-01T00:00:00Z"),
          session("invalid", project, "not-a-date")
        ],
        {
          managedWorktreesRoot: join(root, "managed"),
          temporaryDirectory: join(root, "temporary")
        }
      )
    ).toEqual([
      {
        path: project,
        name: "project",
        sessionCount: 3,
        lastActivity: "2026-02-01T00:00:00Z"
      }
    ])
  })

  it("attributes linked-worktree sessions to their surviving primary checkout", () => {
    const root = makeRoot()
    const primary = join(root, "primary")
    const gitDirectory = join(primary, ".git")
    const worktreeMetadata = join(gitDirectory, "worktrees", "feature")
    const linked = join(root, "feature")
    mkdirSync(worktreeMetadata, { recursive: true })
    mkdirSync(linked)
    writeFileSync(join(linked, ".git"), `gitdir: ${worktreeMetadata}\n`)
    writeFileSync(join(worktreeMetadata, "commondir"), "../..\n")

    expect(
      recommendProjectsFromSessions([session("linked", linked)], {
        managedWorktreesRoot: join(root, "managed"),
        temporaryDirectory: join(root, "temporary")
      })
    ).toEqual([{ path: primary, name: "primary", sessionCount: 1 }])
  })

  it("keeps temporary and managed working folders out of an empty-machine picker", () => {
    const root = makeRoot()
    const managed = join(root, "managed")
    const temporary = join(root, "temporary")
    const internal = join(root, ".codevisor", "internal")
    const darwinTemporary = join(root, "var", "folders", "key", "cache", "T", "checkout")
    mkdirSync(managed)
    mkdirSync(temporary)
    mkdirSync(internal, { recursive: true })
    mkdirSync(darwinTemporary, { recursive: true })

    expect(
      recommendProjectsFromSessions(
        [
          session("managed", managed),
          session("temporary", temporary),
          session("internal", internal),
          session("darwin-temporary", darwinTemporary),
          session("relative", "relative/project"),
          session("root", "/")
        ],
        { managedWorktreesRoot: managed, temporaryDirectory: temporary }
      )
    ).toEqual([])
  })

  it("handles malformed linked-worktree metadata without leaking transient folders", () => {
    const root = makeRoot()
    const repository = join(root, "repository")
    const malformed = join(root, "malformed")
    const emptyPath = join(root, "empty-path")
    const missingCommonDir = join(root, "missing-common-dir")
    const emptyCommonDir = join(root, "empty-common-dir")
    const wrongCommonDir = join(root, "wrong-common-dir")
    const missingPrimary = join(root, "missing-primary")
    for (const path of [
      repository,
      malformed,
      emptyPath,
      missingCommonDir,
      emptyCommonDir,
      wrongCommonDir,
      missingPrimary
    ]) {
      mkdirSync(path)
    }
    mkdirSync(join(repository, ".git"))
    writeFileSync(join(malformed, ".git"), "not git metadata\n")
    writeFileSync(join(emptyPath, ".git"), "gitdir:\n")

    const missingCommonMetadata = join(root, "metadata", "missing-common")
    const emptyCommonMetadata = join(root, "metadata", "empty-common")
    const wrongCommonMetadata = join(root, "metadata", "wrong-common")
    const missingPrimaryMetadata = join(root, "metadata", "missing-primary")
    for (const path of [
      missingCommonMetadata,
      emptyCommonMetadata,
      wrongCommonMetadata,
      missingPrimaryMetadata
    ]) {
      mkdirSync(path, { recursive: true })
    }
    writeFileSync(join(missingCommonDir, ".git"), `gitdir: ${missingCommonMetadata}\n`)
    writeFileSync(join(emptyCommonDir, ".git"), `gitdir: ${emptyCommonMetadata}\n`)
    writeFileSync(join(emptyCommonMetadata, "commondir"), "\n")
    writeFileSync(join(wrongCommonDir, ".git"), `gitdir: ${wrongCommonMetadata}\n`)
    writeFileSync(join(wrongCommonMetadata, "commondir"), "../common\n")
    writeFileSync(join(missingPrimary, ".git"), `gitdir: ${missingPrimaryMetadata}\n`)
    writeFileSync(join(missingPrimaryMetadata, "commondir"), "../gone/.git\n")

    expect(
      recommendProjectsFromSessions(
        [
          session("repository", repository),
          session("malformed", malformed),
          session("empty-path", emptyPath),
          session("missing-common-dir", missingCommonDir),
          session("empty-common-dir", emptyCommonDir),
          session("wrong-common-dir", wrongCommonDir),
          session("missing-primary", missingPrimary)
        ],
        {
          managedWorktreesRoot: join(root, "managed"),
          temporaryDirectory: join(root, "temporary")
        }
      )
    ).toEqual([{ path: repository, name: "repository", sessionCount: 1 }])
  })

  it("honors a bounded result limit", () => {
    const root = makeRoot()
    const alpha = join(root, "alpha")
    const beta = join(root, "beta")
    mkdirSync(alpha)
    mkdirSync(beta)

    expect(
      recommendProjectsFromSessions([session("one", alpha), session("two", beta)], {
        limit: 1,
        managedWorktreesRoot: join(root, "managed"),
        temporaryDirectory: join(root, "temporary")
      })
    ).toHaveLength(1)
    expect(
      recommendProjectsFromSessions([session("one", alpha)], {
        limit: -1,
        managedWorktreesRoot: join(root, "managed"),
        temporaryDirectory: join(root, "temporary")
      })
    ).toEqual([])
  })
})

const makeRoot = (): string => {
  const root = mkdtempSync(join(process.cwd(), ".project-recommendations-"))
  roots.push(root)
  return root
}

const session = (sessionId: string, cwd: string, updatedAt?: string): AgentSessionSummary => ({
  sessionId,
  cwd,
  ...(updatedAt === undefined ? {} : { updatedAt })
})

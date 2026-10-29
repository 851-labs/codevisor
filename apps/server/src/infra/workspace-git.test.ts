import type { EventEnvelope, GitPullRequest } from "@codevisor/api"
import { expect, it, onTestFinished, vi } from "vitest"

import { makeEventFanout, run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import { startWorkspaceGitMonitor } from "./workspace-git.js"

const pullRequest = (number: number): GitPullRequest => ({
  number,
  title: `PR ${number}`,
  state: "open",
  isDraft: false,
  url: `https://github.com/acme/app/pull/${number}`,
  checks: "none"
})

const fixture = async () => {
  const { services } = await makeServices()
  const { db } = services
  const project = await run(db.createProject({ folderPath: "/tmp/workspace-git" }))
  const workspace = (name: string, rootDirectory?: string) =>
    run(
      db.upsertWorkspace({
        projectId: project.id,
        name,
        hasCustomName: false,
        ...(rootDirectory === undefined ? {} : { rootDirectory })
      })
    )
  const fanout = await run(makeEventFanout)
  const published: Array<EventEnvelope> = []
  fanout.subscribe((event) => published.push(event))
  const branches = new Map<string, string | null>()
  const detached = new Map<string, string>()
  const pullRequests = new Map<string, GitPullRequest | null | undefined>()
  const lookups: Array<string> = []
  const missing = new Set<string>()
  const start = () => {
    const monitor = startWorkspaceGitMonitor({
      db,
      fanout,
      checkout: async (record) => {
        if (record.rootDirectory === "/repo/broken") throw new Error("checkout exploded")
        return record.rootDirectory === undefined || missing.has(record.rootDirectory)
          ? undefined
          : { directory: record.rootDirectory }
      },
      environment: async () => ({}),
      headOf: async (directory) => {
        const commit = detached.get(directory)
        if (commit !== undefined) return { branch: null, detachedHead: commit }
        return { branch: branches.get(directory) ?? null }
      },
      pullRequestOf: async (directory, _env, branch) => {
        lookups.push(`${directory}@${branch}`)
        return pullRequests.get(directory)
      },
      branchIntervalMs: 3_600_000,
      pullRequestIntervalMs: 3_600_000
    })
    onTestFinished(() => monitor.close())
    return monitor
  }
  const git = async (id: string) =>
    (await run(db.listWorkspaces)).find((candidate) => candidate.id === id)?.git
  return {
    db,
    fanout,
    published,
    branches,
    detached,
    pullRequests,
    lookups,
    missing,
    workspace,
    start,
    git
  }
}

it("records each workspace's branch and pull request at boot and publishes only changes", async () => {
  const { published, branches, pullRequests, workspace, start, git } = await fixture()
  const feature = await workspace("feature", "/repo/feature")
  const main = await workspace("main", "/repo/main")
  branches.set("/repo/feature", "codevisor/feature").set("/repo/main", "main")
  pullRequests.set("/repo/feature", pullRequest(7)).set("/repo/main", null)

  const monitor = start()
  await monitor.settled()
  const afterBoot = published.length
  await monitor.sweep(true)

  expect(await git(feature.id)).toEqual({
    branch: "codevisor/feature",
    pullRequest: pullRequest(7)
  })
  expect(await git(main.id)).toEqual({ branch: "main", pullRequest: null })
  expect(published.slice(0, afterBoot).every((event) => event.kind === "navigation.changed")).toBe(
    true
  )
  expect(published).toHaveLength(afterBoot)
})

it("checks pull requests on a branch-only sweep when the branch changed", async () => {
  const { branches, pullRequests, lookups, workspace, start, git } = await fixture()
  const feature = await workspace("feature", "/repo/feature")
  branches.set("/repo/feature", "one")
  pullRequests.set("/repo/feature", pullRequest(1))
  const monitor = start()
  await monitor.settled()
  lookups.length = 0

  await monitor.sweep(false)
  expect(lookups).toEqual([])

  branches.set("/repo/feature", "two")
  pullRequests.set("/repo/feature", pullRequest(2))
  await monitor.sweep(false)

  expect(lookups).toEqual(["/repo/feature@two"])
  expect(await git(feature.id)).toEqual({ branch: "two", pullRequest: pullRequest(2) })
})

it("keeps a known pull request when a lookup fails, unless the branch moved on", async () => {
  const { branches, pullRequests, workspace, start, git } = await fixture()
  const feature = await workspace("feature", "/repo/feature")
  branches.set("/repo/feature", "one")
  pullRequests.set("/repo/feature", pullRequest(1))
  const monitor = start()
  await monitor.settled()

  pullRequests.set("/repo/feature", undefined)
  await monitor.sweep(true)
  expect(await git(feature.id)).toEqual({ branch: "one", pullRequest: pullRequest(1) })

  branches.set("/repo/feature", "two")
  await monitor.sweep(true)
  expect(await git(feature.id)).toEqual({ branch: "two", pullRequest: null })
})

it("checks an archived workspace once and a missing checkout as having no branch", async () => {
  const { db, fanout, branches, lookups, workspace, start, git } = await fixture()
  const archived = await workspace("archived", "/repo/archived")
  await run(db.updateWorkspace(archived.id, { isArchived: true }))
  const missing = await workspace("missing")
  branches.set("/repo/archived", "codevisor/archived")
  const monitor = start()
  await monitor.settled()
  lookups.length = 0

  branches.set("/repo/archived", "elsewhere")
  await monitor.sweep(true)
  await run(
    fanout.publish(await run(db.appendEvent("workspace.updated", archived.id, { id: archived.id })))
  )
  await monitor.settled()

  expect(await git(archived.id)).toEqual({ branch: "codevisor/archived", pullRequest: null })
  expect(await git(missing.id)).toEqual({ branch: null, pullRequest: null })
  expect(lookups).toEqual([])
})

it("re-checks a workspace's pull request when one of its chats finishes a turn", async () => {
  const { db, fanout, branches, pullRequests, workspace, start, git } = await fixture()
  const feature = await workspace("feature", "/repo/feature")
  branches.set("/repo/feature", "one")
  pullRequests.set("/repo/feature", null)
  const monitor = start()
  await monitor.settled()

  pullRequests.set("/repo/feature", pullRequest(9))
  const attention = async (sessionId: string, sidebarState: string, workspaceId?: string) =>
    run(
      fanout.publish(
        await run(
          db.appendEvent("session.attention.updated", sessionId, {
            sidebarState,
            ...(workspaceId === undefined ? {} : { workspaceId })
          })
        )
      )
    )
  await attention("idle-session", "needsAttention", feature.id)
  await attention("loose-session", "inProgress")
  await attention("loose-session", "needsAttention")
  await attention("deleted-session", "inProgress", feature.id)
  await run(fanout.publish(await run(db.appendEvent("session.deleted", "deleted-session", {}))))
  await attention("deleted-session", "needsAttention", feature.id)
  await monitor.settled()
  expect(await git(feature.id)).toEqual({ branch: "one", pullRequest: null })

  await attention("session-1", "inProgress", feature.id)
  await attention("session-1", "needsAttention", feature.id)
  await monitor.settled()

  expect(await git(feature.id)).toEqual({ branch: "one", pullRequest: pullRequest(9) })
})

it("re-checks a workspace when it changes and records a detached checkout's commit", async () => {
  const { db, fanout, branches, detached, workspace, start, git } = await fixture()
  const feature = await workspace("feature", "/repo/feature")
  branches.set("/repo/feature", "one")
  const monitor = start()
  await monitor.settled()

  branches.delete("/repo/feature")
  detached.set("/repo/feature", "e6a622bef")
  const publish = async (subjectId: string) =>
    run(
      fanout.publish(await run(db.appendEvent("workspace.updated", subjectId, { id: subjectId })))
    )
  await publish(feature.id.toUpperCase())
  await publish("00000000-0000-4000-8000-00000000dead")
  await monitor.settled()

  expect(await git(feature.id)).toEqual({
    branch: null,
    detachedHead: "e6a622bef",
    pullRequest: null
  })
})

it("logs a failed check and keeps checking the other workspaces", async () => {
  const { branches, workspace, start, git } = await fixture()
  const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
  onTestFinished(() => errors.mockRestore())
  await workspace("broken", "/repo/broken")
  const feature = await workspace("feature", "/repo/feature")
  branches.set("/repo/feature", "one")

  const monitor = start()
  await monitor.settled()

  expect(await git(feature.id)).toMatchObject({ branch: "one" })
  expect(errors).toHaveBeenCalledWith(expect.stringContaining("checkout exploded"))
})

it("starts checking workspaces created after it booted with nothing to check", async () => {
  const { db, fanout, branches, workspace, start, git } = await fixture()
  const monitor = start()
  await monitor.settled()

  const created = await workspace("created", "/repo/created")
  branches.set("/repo/created", "fresh")
  await run(
    fanout.publish(await run(db.appendEvent("workspace.updated", created.id, { id: created.id })))
  )
  await monitor.settled()

  expect(await git(created.id)).toEqual({ branch: "fresh", pullRequest: null })
})

it("clears an active workspace's git once its checkout is gone", async () => {
  const { branches, missing, workspace, start, git } = await fixture()
  const feature = await workspace("feature", "/repo/feature")
  branches.set("/repo/feature", "one")
  const monitor = start()
  await monitor.settled()

  missing.add("/repo/feature")
  await monitor.sweep(false)

  expect(await git(feature.id)).toEqual({ branch: null, pullRequest: null })
})

it("keeps checking an archived workspace's open pull request until it closes", async () => {
  const { db, branches, pullRequests, lookups, missing, workspace, start, git } = await fixture()
  const archived = await workspace("archived", "/repo/archived")
  branches.set("/repo/archived", "feature")
  pullRequests.set("/repo/archived", pullRequest(3))
  const monitor = start()
  await monitor.settled()
  await run(db.updateWorkspace(archived.id, { isArchived: true }))
  lookups.length = 0

  await monitor.sweep(false)
  expect(lookups).toEqual([])
  missing.add("/repo/archived")
  await monitor.sweep(true)
  expect(await git(archived.id)).toEqual({ branch: "feature", pullRequest: pullRequest(3) })
  missing.delete("/repo/archived")

  pullRequests.set("/repo/archived", { ...pullRequest(3), state: "merged" })
  await monitor.sweep(true)
  await monitor.sweep(true)

  expect(await git(archived.id)).toEqual({
    branch: "feature",
    pullRequest: { ...pullRequest(3), state: "merged" }
  })
  expect(lookups).toEqual(["/repo/archived@feature"])
})

it("does no more work once closed", async () => {
  const { branches, workspace, start, git } = await fixture()
  const feature = await workspace("feature", "/repo/feature")
  branches.set("/repo/feature", "one")
  const monitor = start()
  await monitor.settled()

  await monitor.close()
  branches.set("/repo/feature", "two")
  await monitor.sweep(false)

  expect(await git(feature.id)).toMatchObject({ branch: "one" })
})

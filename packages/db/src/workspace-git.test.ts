import { expect, it } from "vitest"

import { memoryDatabase, navigationDelta, run } from "./test-support.js"

const pullRequest = {
  number: 42,
  title: "Ship it",
  state: "open",
  isDraft: false,
  url: "https://github.com/acme/app/pull/42",
  checks: "passing"
} as const

const workspaceFixture = async () => {
  const fixture = await memoryDatabase()
  const workspace = await run(
    fixture.db.upsertWorkspace({
      projectId: fixture.project.id,
      name: "work",
      hasCustomName: false,
      rootDirectory: "/work/app"
    })
  )
  const read = async () =>
    (await run(fixture.db.listWorkspaces)).find((candidate) => candidate.id === workspace.id)
  return { ...fixture, workspace, read }
}

it("records the branch and pull request and journals only real changes", async () => {
  const { db, workspace, read } = await workspaceFixture()

  const first = await run(
    db.setWorkspaceGit(workspace.id.toUpperCase(), { branch: "feature" }, pullRequest)
  )
  const repeated = await run(db.setWorkspaceGit(workspace.id, { branch: "feature" }, pullRequest))

  expect((await read())?.git).toEqual({ branch: "feature", pullRequest })
  expect(first.map((event) => [event.kind, event.subjectId])).toContainEqual([
    "navigation.changed",
    workspace.id
  ])
  expect(repeated).toEqual([])
})

it("keeps the known pull request when only the branch is checked", async () => {
  const { db, workspace, read } = await workspaceFixture()
  await run(db.setWorkspaceGit(workspace.id, { branch: "feature" }, pullRequest))

  const unchanged = await run(db.setWorkspaceGit(workspace.id, { branch: "feature" }, undefined))
  await run(db.setWorkspaceGit(workspace.id, { branch: "renamed" }, undefined))

  expect(unchanged).toEqual([])
  expect((await read())?.git).toEqual({ branch: "renamed", pullRequest })
})

it("leaves git unknown until checked, then records a checkout with no branch or pull request as known", async () => {
  const { db, workspace, read } = await workspaceFixture()
  expect((await read())?.git).toBeUndefined()

  const events = await run(db.setWorkspaceGit(workspace.id, { branch: null }, null))

  expect(events).not.toEqual([])
  expect((await read())?.git).toEqual({ branch: null, pullRequest: null })
})

it("records a detached HEAD's commit and clears it once a branch is checked out", async () => {
  const { db, workspace, read } = await workspaceFixture()

  const detached = await run(
    db.setWorkspaceGit(workspace.id, { branch: null, detachedHead: "e6a622bef" }, null)
  )
  expect(detached).not.toEqual([])
  expect((await read())?.git).toEqual({
    branch: null,
    detachedHead: "e6a622bef",
    pullRequest: null
  })

  const moved = await run(
    db.setWorkspaceGit(workspace.id, { branch: null, detachedHead: "c1c800ab2" }, undefined)
  )
  expect(moved).not.toEqual([])

  await run(db.setWorkspaceGit(workspace.id, { branch: "feature" }, undefined))
  expect((await read())?.git).toStrictEqual({ branch: "feature", pullRequest: null })
})

it("survives a client saving the workspace again", async () => {
  const { db, project, workspace, read } = await workspaceFixture()
  await run(db.setWorkspaceGit(workspace.id, { branch: "feature" }, pullRequest))

  await run(
    db.upsertWorkspace({
      id: workspace.id,
      projectId: project.id,
      name: "renamed",
      hasCustomName: true
    })
  )

  expect(await read()).toMatchObject({ name: "renamed", git: { branch: "feature", pullRequest } })
})

it("treats a stored pull request it can no longer read as none", async () => {
  const { db, sqlite, workspace, read } = await workspaceFixture()
  await run(db.setWorkspaceGit(workspace.id, { branch: "feature" }, pullRequest))

  sqlite
    .prepare("update checkouts set git_pull_request = ? where id = ?")
    .run("{", workspace.defaultCheckoutId)

  expect((await read())?.git).toEqual({ branch: "feature", pullRequest: null })
})

it("gives every workspace in a folder the branch and pull request found there", async () => {
  const { db, project, workspace } = await workspaceFixture()
  const beside = await run(
    db.upsertWorkspace({
      projectId: project.id,
      name: "beside",
      hasCustomName: false,
      rootDirectory: "/work/app"
    })
  )
  const cursor = (await run(db.getNavigationSnapshot)).eventCursor

  await run(db.setWorkspaceGit(workspace.id, { branch: "feature" }, pullRequest))

  const workspaces = await run(db.listWorkspaces)
  expect(workspaces.find((candidate) => candidate.id === beside.id)?.git).toEqual({
    branch: "feature",
    pullRequest
  })
  const batch = await run(db.readSyncBatch(cursor))
  const sent = batch.events
    .filter((event) => event.kind === "navigation.changed")
    .flatMap((event) => navigationDelta(event).workspaces.map((changed) => changed.id))
  expect(sent.toSorted()).toEqual([workspace.id, beside.id].toSorted())
})

it("knows a workspace with no folder has no branch or pull request", async () => {
  const fixture = await memoryDatabase()

  const workspace = await run(
    fixture.db.upsertWorkspace({
      projectId: fixture.project.id,
      name: "loose",
      hasCustomName: false
    })
  )

  expect(workspace.git).toEqual({ branch: null, pullRequest: null })
  expect(workspace.rootDirectory).toBeUndefined()
})

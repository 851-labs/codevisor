import Database from "better-sqlite3"
import { Effect } from "effect"
import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"
import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { foodWorktreeNames, productionFoodWorktreeNames } from "@codevisor/worktrees"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  start,
  tempDirs,
  waitFor
} from "../test-support.js"

describe("project routes", () => {
  it("clones a git remote into the managed repos dir as a project", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })

    const reposRoot = mkdtempSync(join(tmpdir(), "codevisor-repos-"))
    tempDirs.push(reposRoot)
    process.env["CODEVISOR_REPOS_ROOT"] = reposRoot
    try {
      const { server, services } = await start()
      const origin = mkdtempSync(join(tmpdir(), "codevisor-origin-"))
      tempDirs.push(origin)
      const originRepo = join(origin, "widget.git")
      mkdirSync(originRepo)
      await git(["init"], originRepo)
      writeFileSync(join(originRepo, "README.md"), "hello")
      await git(["add", "."], originRepo)
      await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"], originRepo)

      const url = `file://${originRepo}`
      const created = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "cloned-project", url }),
        method: "POST"
      })
      expect(created.status).toBe(201)
      expect(created.body).toMatchObject({
        id: "cloned-project",
        name: "widget",
        repoUrl: url,
        locations: [{ folderPath: join(reposRoot, "widget"), isGitRepository: true }]
      })
      expect(existsSync(join(reposRoot, "widget", "README.md"))).toBe(true)

      // Clone progress reached the event log under the client-supplied id.
      const events = await run(services.db.listSubjectEvents("cloned-project"))
      const states = events
        .filter((event) => event.kind === "project.setup")
        .map((event) => (event.payload as { state: string }).state)
      expect(states[0]).toBe("started")
      expect(states.at(-1)).toBe("completed")

      // A second clone of the same remote under an explicit name gets its
      // own directory and a server-generated project id.
      const renamed = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url, name: "widget-two" }),
        method: "POST"
      })
      expect(renamed.status).toBe(201)
      expect(renamed.body).toMatchObject({
        name: "widget-two",
        locations: [{ folderPath: join(reposRoot, "widget-two") }]
      })

      // Same destination again: conflict, with an actionable code.
      const duplicate = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url }),
        method: "POST"
      })
      expect(duplicate.status).toBe(409)
      expect(duplicate.body).toMatchObject({ code: "already_exists" })

      // Not a git URL at all.
      const invalid = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "not a url" }),
        method: "POST"
      })
      expect(invalid.status).toBe(400)
      expect(invalid.body).toMatchObject({ code: "invalid_url" })

      // A URL no project name can be derived from (scp-style syntax).
      const unnameable = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "git@example.com:acme/--.git" }),
        method: "POST"
      })
      expect(unnameable.status).toBe(400)
      expect((unnameable.body as { error: string }).error).toContain("name")

      // A well-formed URL to a repo that does not exist: the clone fails with
      // a classified error, publishes `failed`, and leaves no partial dir.
      const missing = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "missing-project", url: `file://${origin}/gone.git` }),
        method: "POST"
      })
      expect(missing.status).toBe(422)
      expect((missing.body as { code?: string }).code).toBeDefined()
      expect(existsSync(join(reposRoot, "gone"))).toBe(false)
      const failedEvents = await run(services.db.listSubjectEvents("missing-project"))
      expect(
        failedEvents.some(
          (event) =>
            event.kind === "project.setup" &&
            (event.payload as { state: string }).state === "failed"
        )
      ).toBe(true)
    } finally {
      delete process.env["CODEVISOR_REPOS_ROOT"]
    }
  })

  it("cascades archive across projects, workspaces, and chats with provenance", async () => {
    const { server } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-cascade-"))
    tempDirs.push(folder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id: "cascade-project" }),
      method: "POST"
    })
    // A workspace in an unrelated project, present for every cascade below: it
    // must never be republished, or clients would move rows that never changed.
    const otherFolder = mkdtempSync(join(tmpdir(), "codevisor-cascade-other-"))
    tempDirs.push(otherFolder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: otherFolder, id: "bystander-project" }),
      method: "POST"
    })
    await jsonRequest(server, "/v1/workspaces/bystander-workspace", {
      body: JSON.stringify({
        projectId: "bystander-project",
        name: "bystander",
        hasCustomName: false
      }),
      method: "PUT"
    })
    const workspace = (
      await jsonRequest(server, "/v1/workspaces/cascade-workspace", {
        body: JSON.stringify({
          projectId: "cascade-project",
          name: "main",
          hasCustomName: false
        }),
        method: "PUT"
      })
    ).body as { readonly id: string }

    const makeSession = async (id: string) =>
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ id, projectId: "cascade-project", harnessId: "codex" }),
          method: "POST"
        })
      ).body as { readonly id: string }
    const cascaded = await makeSession("cascade-chat")
    const handArchived = await makeSession("hand-archived-chat")

    // The user archives one chat themselves, before any cascade runs.
    await jsonRequest(server, `/v1/sessions/${handArchived.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    const archivedStateOf = async (id: string) =>
      (
        (await jsonRequest(server, "/v1/sessions")).body as ReadonlyArray<{
          readonly id: string
          readonly isArchived: boolean
        }>
      ).find((session) => session.id === id)?.isArchived
    const workspaceArchived = async () =>
      (
        (await jsonRequest(server, "/v1/workspaces")).body as ReadonlyArray<{
          readonly id: string
          readonly isArchived: boolean
        }>
      ).find((candidate) => candidate.id === workspace.id)?.isArchived

    await jsonRequest(server, "/v1/projects/cascade-project", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(await archivedStateOf(cascaded.id)).toBe(true)
    expect(await workspaceArchived()).toBe(true)

    await jsonRequest(server, "/v1/projects/cascade-project", {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(await archivedStateOf(cascaded.id)).toBe(false)
    expect(await workspaceArchived()).toBe(false)
    // Provenance: the chat the user archived by hand is NOT resurrected by
    // unarchiving the project around it.
    expect(await archivedStateOf(handArchived.id)).toBe(true)

    // A workspace PATCH cascades one level down, to its own chats only.
    const inWorkspace = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "workspace-chat",
          projectId: "cascade-project",
          harnessId: "codex",
          workspaceId: workspace.id
        }),
        method: "POST"
      })
    ).body as { readonly id: string }

    await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(await archivedStateOf(inWorkspace.id)).toBe(true)
    // A sibling chat outside the workspace is untouched.
    expect(await archivedStateOf(cascaded.id)).toBe(false)

    await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(await archivedStateOf(inWorkspace.id)).toBe(false)

    const bystander = (
      (await jsonRequest(server, "/v1/workspaces")).body as ReadonlyArray<{
        readonly id: string
        readonly isArchived: boolean
      }>
    ).find((candidate) => candidate.id === "bystander-workspace")
    expect(bystander?.isArchived).toBe(false)

    // A PATCH that says nothing about archiving skips the cascade entirely
    // rather than republishing every session as unchanged.
    const renamed = await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ name: "renamed" }),
      method: "PATCH"
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body).toMatchObject({ name: "renamed", isArchived: false })
    expect(await archivedStateOf(inWorkspace.id)).toBe(false)
  })

  it("archives a chat with no worktree without touching the filesystem", async () => {
    // Non-git projects never get a worktree, so archiving is a pure flag flip
    // — the snapshot machinery must not engage at all.
    const { server } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-plain-archive-"))
    tempDirs.push(folder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id: "plain-archive-project" }),
      method: "POST"
    })
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "plain-archive-project",
          harnessId: "test",
          deferAgentSession: true
        }),
        method: "POST"
      })
    ).body as { readonly id: string }

    const archived = await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(archived.body).toMatchObject({ isArchived: true })

    // Restoring finds no snapshot record and still succeeds.
    const restored = await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(restored.body).toMatchObject({ isArchived: false })
    expect(existsSync(folder)).toBe(true)
  })

  it("addresses projects by id case-insensitively", async () => {
    const { server } = await start()
    const lowerId = "0d604f39-364b-4a17-8fd8-21bddd8c1399"
    const upperId = lowerId.toUpperCase()

    // A client that sends an uppercase UUID (Swift) has it canonicalized to
    // lowercase, so ids stay consistent across clients.
    const created = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    expect((created.body as { id: string }).id).toBe(lowerId)

    // Re-syncing the same project (uppercase again) is idempotent — no
    // duplicate row, no merge into a differently-cased id.
    const resync = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect((resync.body as { id: string }).id).toBe(lowerId)
    expect(((await jsonRequest(server, "/v1/projects")).body as Array<unknown>).length).toBe(1)

    // A client that stores the id uppercase (Swift's UUID) resolves the
    // lowercase-stored project instead of hitting a spurious "Project not
    // found". (A later 4xx for harness/account reasons is unrelated.)
    const session = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ projectId: upperId, harnessId: "codex" }),
      method: "POST"
    })
    expect(session.status).not.toBe(404)
    expect(JSON.stringify(session.body)).not.toContain("Project not found")

    // The worktree route resolves the project by the uppercase URL id too.
    const worktree = await jsonRequest(server, `/v1/projects/${upperId}/worktrees`, {
      body: JSON.stringify({ name: "feature" }),
      method: "POST"
    })
    expect(worktree.status).not.toBe(404)
    expect(JSON.stringify(worktree.body)).not.toContain("Project not found")
  })

  it("creates worktrees and runs worktree sessions in them", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })

    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-worktrees-"))
    tempDirs.push(worktreesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { agents, server, services } = await start()
      // makeServices' temp dir (the newest entry) holds the server database.
      const serverDatabasePath = join(tempDirs[tempDirs.length - 1] as string, "codevisor.sqlite")
      const repoRoot = mkdtempSync(join(tmpdir(), "codevisor-repo-"))
      tempDirs.push(repoRoot)
      const repoFolder = join(repoRoot, "repo")
      const plainFolder = join(repoRoot, "plain")
      mkdirSync(repoFolder)
      mkdirSync(plainFolder)
      await git(["init"], repoFolder)
      await git(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
        repoFolder
      )

      const projectResponse = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: repoFolder, id: "git-project" }),
        method: "POST"
      })
      expect(projectResponse.status).toBe(201)
      expect(projectResponse.body).toMatchObject({
        id: "git-project",
        locations: [{ serverId: "server-a", folderPath: repoFolder, isGitRepository: true }]
      })

      const plainResponse = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
        method: "POST"
      })
      expect(plainResponse.body).toMatchObject({
        locations: [{ isGitRepository: false }]
      })

      // Worktree creation on a non-git project is refused.
      expect(
        (
          await jsonRequest(server, "/v1/projects/plain-project/worktrees", {
            body: JSON.stringify({ name: "nope" }),
            method: "POST"
          })
        ).status
      ).toBe(422)

      // A client-supplied id keys the worktree row and its setup events so
      // callers can follow progress while the create request is in flight.
      const worktreeResponse = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({
          id: "wt-fix-auth",
          name: "Fix Auth!",
          sessionId: "session-awaiting-worktree"
        }),
        method: "POST"
      })
      expect(worktreeResponse.status).toBe(201)
      const worktree = worktreeResponse.body as {
        readonly id: string
        readonly name: string
        readonly branch: string
        readonly path: string
      }
      expect(worktree).toMatchObject({
        id: "wt-fix-auth",
        projectId: "git-project",
        serverId: "server-a"
      })
      // A custom name stays clean when it is available.
      expect(worktree.name).toBe("fix-auth")
      expect(worktree.branch).toBe(`codevisor/${worktree.name}`)
      expect(worktree.path).toBe(join(worktreesRoot, "git-project", worktree.name))
      expect(existsSync(join(worktree.path, ".git"))).toBe(true)

      // Setup progress was streamed as ordered worktree.setup events: started,
      // git output lines (git narrates "Preparing worktree ..." on stderr),
      // then completed with the elapsed duration.
      const setupPayloads = (await run(services.db.listEvents(0)))
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-fix-auth")
        .map(
          (event) =>
            event.payload as {
              readonly state: string
              readonly stream?: string
              readonly line?: string
              readonly durationMs?: number
            }
        )
      expect(setupPayloads[0]).toMatchObject({
        state: "started",
        worktreeId: "wt-fix-auth",
        projectId: "git-project",
        name: worktree.name,
        branch: worktree.branch
      })
      const logPayloads = setupPayloads.filter((payload) => payload.state === "log")
      expect(logPayloads.length).toBeGreaterThan(0)
      expect(logPayloads.every((payload) => (payload.line ?? "").length > 0)).toBe(true)
      expect(
        logPayloads.every((payload) => payload.stream === "stdout" || payload.stream === "stderr")
      ).toBe(true)
      const lastSetup = setupPayloads[setupPayloads.length - 1]
      expect(lastSetup?.state).toBe("completed")
      expect(lastSetup?.durationMs).toBeGreaterThanOrEqual(0)
      const mirroredSetupPayloads = (await run(services.db.listEvents(0))).filter(
        (event) =>
          event.kind === "worktree.setup" && event.subjectId === "session-awaiting-worktree"
      )
      expect(
        mirroredSetupPayloads.map((event) => (event.payload as { state: string }).state)
      ).toEqual(setupPayloads.map((payload) => payload.state))
      const mirroredSetupHistory = (
        await jsonRequest(server, "/v1/sessions/session-awaiting-worktree/events")
      ).body as ReadonlyArray<{ readonly kind: string; readonly subjectId: string }>
      expect(mirroredSetupHistory).toHaveLength(mirroredSetupPayloads.length)
      expect(mirroredSetupHistory.every((event) => event.kind === "worktree.setup")).toBe(true)

      // Repeated custom names get a readable sequence number.
      const secondWorktree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "fix auth" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(secondWorktree.name).toBe("fix-auth-2")
      expect(secondWorktree.branch).toBe(`codevisor/${secondWorktree.name}`)
      const thirdWorktree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "fix auth" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(thirdWorktree.name).toBe("fix-auth-3")
      expect(thirdWorktree.branch).toBe(`codevisor/${thirdWorktree.name}`)
      // Missing names get a compact food word from the curated production pool.
      const randomNamed = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(productionFoodWorktreeNames).toContain(randomNamed.name)
      expect(randomNamed.branch).toBe(`codevisor/${randomNamed.name}`)
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(4)

      // Git refs outlive archived database rows and are shared by isolated
      // development servers. A stale branch is included in allocation, so
      // the request transparently moves to the next readable name.
      await git(["branch", "codevisor/doomed"], repoFolder)
      const recovered = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ id: "wt-doomed", name: "doomed" }),
        method: "POST"
      })
      expect(recovered.status).toBe(201)
      expect(recovered.body).toMatchObject({
        id: "wt-doomed",
        name: "doomed-2",
        branch: "codevisor/doomed-2"
      })
      const recoveredSetup = (await run(services.db.listEvents(0)))
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-doomed")
        .map((event) => (event.payload as { readonly state: string }).state)
      expect(recoveredSetup[0]).toBe("started")
      expect(recoveredSetup.at(-1)).toBe("completed")
      expect(recoveredSetup).not.toContain("failed")
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(5)

      // Sessions created with a worktree run the agent inside the worktree.
      const sessionResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "git-project",
          harnessId: "codex",
          worktreeName: worktree.name,
          title: "Worktree chat"
        }),
        method: "POST"
      })
      expect(sessionResponse.status).toBe(201)
      const session = sessionResponse.body as {
        readonly id: string
        readonly agentSessionId: string
        readonly cwd: string
        readonly worktreeName: string
      }
      expect(session.worktreeName).toBe(worktree.name)
      expect(session.cwd).toBe(worktree.path)
      expect(agents.creations).toContainEqual(["codex", worktree.path])
      const sessionHistory = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string; readonly subjectId: string }>
      expect(sessionHistory).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ kind: "worktree.setup", subjectId: worktree.id })
        ])
      )

      // Reattaching (prompt after restart) resolves the same worktree cwd.
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "hello worktree" }),
        method: "POST"
      })
      await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello worktree"))
      expect(agents.loads).toContainEqual(["codex", session.agentSessionId, worktree.path])

      // Archiving a session deletes its worktree from disk once no active
      // session still relies on it. Set up a dedicated worktree shared by two
      // sessions plus an unrelated session in another project.
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "plain-project", harnessId: "codex" }),
        method: "POST"
      })
      const solo = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "solo work" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly path: string }
      expect(existsSync(solo.path)).toBe(true)
      const worktreeNames = async () =>
        (
          (await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as ReadonlyArray<{
            readonly name: string
          }>
        ).map((entry) => entry.name)
      const soloSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: solo.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const sharer = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: solo.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }

      // The worktree survives while another active session still uses it.
      await jsonRequest(server, `/v1/sessions/${soloSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)

      // Archiving the final active session removes it from git and disk.
      await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(existsSync(solo.path)).toBe(false)
      expect(await worktreeNames()).not.toContain(solo.name)
      const removedWorktreeHistory = (await jsonRequest(server, `/v1/sessions/${sharer.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string }>
      expect(removedWorktreeHistory.some((event) => event.kind === "worktree.setup")).toBe(false)

      // Re-archiving once the worktree record is gone is a harmless no-op.
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
            body: JSON.stringify({ isArchived: true }),
            method: "PATCH"
          })
        ).status
      ).toBe(200)

      // Unarchiving rebuilds the worktree from its snapshot and reclaims the
      // freed name, so the restored chat resolves to the same cwd as before.
      const restored = (
        await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
          body: JSON.stringify({ isArchived: false }),
          method: "PATCH"
        })
      ).body as {
        readonly worktreeName: string
        readonly cwd: string
        readonly isArchived: boolean
      }
      expect(restored.isArchived).toBe(false)
      expect(restored.worktreeName).toBe(solo.name)
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)
      expect(restored.cwd).toBe(solo.path)

      // The restore is announced as its own event kind: clients must move the
      // row between sidebar sections, not just repaint it.
      const restoreHistory = (await jsonRequest(server, `/v1/sessions/${sharer.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string }>
      expect(restoreHistory.some((event) => event.kind === "session.unarchived")).toBe(true)

      // The other session that shared the worktree is still archived, and
      // unarchiving it now simply reattaches to the live worktree.
      const rejoined = (
        await jsonRequest(server, `/v1/sessions/${soloSession.id}`, {
          body: JSON.stringify({ isArchived: false }),
          method: "PATCH"
        })
      ).body as { readonly worktreeName: string; readonly cwd: string }
      expect(rejoined.worktreeName).toBe(solo.name)
      expect(rejoined.cwd).toBe(solo.path)
      expect(await worktreeNames()).toContain(solo.name)

      // Gitignored files are not snapshotted — putting a .env into a git
      // object that may later be pushed is worse than losing it — so the
      // client is told exactly what went away with the worktree.
      const ignoredTree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "with ignored" }),
          method: "POST"
        })
      ).body as { readonly id: string; readonly name: string; readonly path: string }
      writeFileSync(join(ignoredTree.path, ".gitignore"), ".env\n")
      writeFileSync(join(ignoredTree.path, ".env"), "SECRET=1\n")
      const ignoredSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: ignoredTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      // A second chat in the same worktree: when the restore has to rename,
      // every chat pointing at the old name must follow it, not just the one
      // being unarchived.
      const ignoredSibling = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: ignoredTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      await jsonRequest(server, `/v1/sessions/${ignoredSibling.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      await jsonRequest(server, `/v1/sessions/${ignoredSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      const ignoredHistory = (await jsonRequest(server, `/v1/sessions/${ignoredSession.id}/events`))
        .body as ReadonlyArray<{
        readonly kind: string
        readonly payload?: { readonly archiveDroppedIgnoredPaths?: ReadonlyArray<string> }
      }>
      expect(
        ignoredHistory.some((event) =>
          event.payload?.archiveDroppedIgnoredPaths?.some((path) => path.endsWith(".env"))
        )
      ).toBe(true)

      // The freed name is taken by a new worktree before the restore, so the
      // chat comes back under a suffixed name rather than colliding.
      const squatter = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: ignoredTree.name }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly path: string }
      expect(squatter.name).toBe(ignoredTree.name)
      const suffixed = (
        await jsonRequest(server, `/v1/sessions/${ignoredSession.id}`, {
          body: JSON.stringify({ isArchived: false }),
          method: "PATCH"
        })
      ).body as { readonly worktreeName: string; readonly cwd: string }
      // Restored under its own name plus a suffix, and — critically — into
      // its own directory rather than adopting the squatter's.
      expect(suffixed.worktreeName).not.toBe(ignoredTree.name)
      expect(suffixed.worktreeName.startsWith(ignoredTree.name)).toBe(true)
      expect(suffixed.cwd).not.toBe(squatter.path)
      expect(existsSync(suffixed.cwd)).toBe(true)
      // The sibling's pointer was rewritten too, so unarchiving it later finds
      // the worktree under its new name instead of a name nobody owns.
      const siblingAfterRename = (await jsonRequest(server, `/v1/sessions/${ignoredSibling.id}`))
        .body as { readonly session: { readonly worktreeName: string } }
      expect(siblingAfterRename.session.worktreeName).toBe(suffixed.worktreeName)

      // A snapshot that has gone missing (an archive predating snapshots, or a
      // pruned ref) still unarchives — the chat is what matters — but says so
      // rather than pretending the files came back.
      const orphanTree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "orphan" }),
          method: "POST"
        })
      ).body as { readonly id: string; readonly name: string }
      const orphanSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: orphanTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      await jsonRequest(server, `/v1/sessions/${orphanSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      await Effect.runPromise(services.db.deleteArchivedWorktree(orphanTree.id))
      const orphanRestored = await jsonRequest(server, `/v1/sessions/${orphanSession.id}`, {
        body: JSON.stringify({ isArchived: false }),
        method: "PATCH"
      })
      expect(orphanRestored.body).toMatchObject({ isArchived: false })
      const orphanHistory = (await jsonRequest(server, `/v1/sessions/${orphanSession.id}/events`))
        .body as ReadonlyArray<{
        readonly payload?: { readonly archiveRestoreIncomplete?: boolean }
      }>
      expect(orphanHistory.some((event) => event.payload?.archiveRestoreIncomplete === true)).toBe(
        true
      )

      // A chat pointing at a worktree row that no longer exists archives
      // cleanly: there is nothing to snapshot, so it is a plain flag flip.
      const strayTree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "stray" }),
          method: "POST"
        })
      ).body as { readonly id: string; readonly name: string }
      const straySession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: strayTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      await Effect.runPromise(services.db.deleteWorktree(strayTree.id))
      const strayArchived = await jsonRequest(server, `/v1/sessions/${straySession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(strayArchived.body).toMatchObject({ isArchived: true })

      // Archiving a session that never had a worktree leaves worktrees intact.
      const plainSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId: "git-project", harnessId: "codex" }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const before = (await worktreeNames()).length
      await jsonRequest(server, `/v1/sessions/${plainSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect((await worktreeNames()).length).toBe(before)

      // A recorded worktree whose folder vanished is rejected too.
      rmSync(worktree.path, { force: true, recursive: true })
      await git(["worktree", "prune"], repoFolder)
      const missingFolder = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "git-project",
          harnessId: "codex",
          worktreeName: worktree.name,
          title: "Missing worktree"
        }),
        method: "POST"
      })
      expect(missingFolder.status).toBe(400)
      expect((missingFolder.body as { readonly error: string }).error).toContain(
        "Worktree folder does not exist"
      )

      // A project whose only folder lives on another machine can't host
      // sessions here.
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: join(repoRoot, "detached"), id: "detached-project" }),
        method: "POST"
      })
      const sqlite = new Database(serverDatabasePath)
      sqlite
        .prepare("update project_locations set server_id = 'server-elsewhere' where project_id = ?")
        .run("detached-project")
      sqlite.close()
      const detached = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "detached-project", harnessId: "codex" }),
        method: "POST"
      })
      expect(detached.status).toBe(400)
      expect((detached.body as { readonly error: string }).error).toContain(
        "no folder on this machine"
      )

      // Unknown worktree names are rejected.
      expect(
        (
          await jsonRequest(server, "/v1/sessions", {
            body: JSON.stringify({
              projectId: "git-project",
              harnessId: "codex",
              worktreeName: "does-not-exist"
            }),
            method: "POST"
          })
        ).status
      ).toBe(400)
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })

  it("uses food names with four-digit suffixes for development worktrees", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })
    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-development-worktrees-"))
    tempDirs.push(worktreesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { services } = await makeServices("server-dev")
      const server = await run(
        startCodevisorServer(
          services,
          defaultServerConfig({
            id: "server-dev",
            port: 0,
            worktreeNameStyle: "development"
          })
        )
      )
      runningServers.push(server)
      const repoFolder = mkdtempSync(join(tmpdir(), "codevisor-development-repo-"))
      tempDirs.push(repoFolder)
      await git(["init"], repoFolder)
      await git(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
        repoFolder
      )
      expect(
        (
          await jsonRequest(server, "/v1/projects", {
            body: JSON.stringify({ folderPath: repoFolder, id: "food-project" }),
            method: "POST"
          })
        ).status
      ).toBe(201)

      const response = await jsonRequest(server, "/v1/projects/food-project/worktrees", {
        method: "POST"
      })
      expect(response.status).toBe(201)
      const name = (response.body as { readonly name: string }).name
      const match = /^(.*)-(\d{4})$/.exec(name)
      expect(match).not.toBeNull()
      expect(foodWorktreeNames).toContain(match?.[1])

      // Scratch workspace folders draw from the same development pool.
      const scratch = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(scratch.status).toBe(201)
      const scratchName = (scratch.body as { readonly name: string }).name
      const scratchMatch = /^(.*)-(\d{4})$/.exec(scratchName)
      expect(scratchMatch).not.toBeNull()
      expect(foodWorktreeNames).toContain(scratchMatch?.[1])
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })

  it("creates scratch workspace projects and re-homes their sessions before the agent starts", async () => {
    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-scratch-root-"))
    tempDirs.push(worktreesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { server } = await start()

      const created = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({ id: "scratch-project" }),
        method: "POST"
      })
      expect(created.status).toBe(201)
      const scratch = created.body as {
        readonly id: string
        readonly name: string
        readonly isScratch?: boolean
        readonly locations: ReadonlyArray<{ readonly folderPath: string }>
      }
      expect(scratch.id).toBe("scratch-project")
      expect(scratch.isScratch).toBe(true)
      const scratchFolder = scratch.locations[0]?.folderPath as string
      expect(scratchFolder).toBe(join(worktreesRoot, "workspaces", scratch.name))
      expect(existsSync(scratchFolder)).toBe(true)

      // Idempotent per client-supplied id: replaying returns the existing
      // project instead of allocating a second folder.
      const replay = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({ id: "scratch-project" }),
        method: "POST"
      })
      expect(replay.status).toBe(200)
      expect((replay.body as { readonly id: string }).id).toBe("scratch-project")
      expect(readdirSync(join(worktreesRoot, "workspaces"))).toHaveLength(1)

      // Without a client id the server mints one — and a fresh folder.
      const anonymous = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(anonymous.status).toBe(201)
      expect((anonymous.body as { readonly isScratch?: boolean }).isScratch).toBe(true)
      expect(readdirSync(join(worktreesRoot, "workspaces"))).toHaveLength(2)

      // An ordinary project is not flagged as scratch.
      const plainFolder = mkdtempSync(join(tmpdir(), "codevisor-plain-"))
      tempDirs.push(plainFolder)
      const plain = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
        method: "POST"
      })
      expect(plain.status).toBe(201)
      expect((plain.body as { readonly isScratch?: boolean }).isScratch).toBeUndefined()

      // A deferred session starts life in the scratch folder…
      const sessionResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "scratch-session",
          projectId: "scratch-project",
          harnessId: "codex",
          deferAgentSession: true
        }),
        method: "POST"
      })
      expect(sessionResponse.status).toBe(201)
      expect((sessionResponse.body as { readonly cwd?: string }).cwd).toBe(scratchFolder)

      // …and can be re-homed to a real project while the agent hasn't started.
      const moved = await jsonRequest(server, "/v1/sessions/scratch-session", {
        body: JSON.stringify({ projectId: "plain-project" }),
        method: "PATCH"
      })
      expect(moved.status).toBe(200)
      expect(moved.body).toMatchObject({ projectId: "plain-project", cwd: plainFolder })

      // Moving to a project with no folder on this machine is refused up front.
      expect(
        (
          await jsonRequest(server, "/v1/sessions/scratch-session", {
            body: JSON.stringify({ projectId: "missing-project" }),
            method: "PATCH"
          })
        ).status
      ).toBe(404)

      // Once an agent session exists the move is refused.
      const startedResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "plain-project", harnessId: "codex" }),
        method: "POST"
      })
      expect(startedResponse.status).toBe(201)
      const startedId = (startedResponse.body as { readonly id: string }).id
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${startedId}`, {
            body: JSON.stringify({ projectId: "scratch-project" }),
            method: "PATCH"
          })
        ).status
      ).toBe(409)

      // Deleting the scratch project retires its (still empty) folder.
      expect(
        (await jsonRequest(server, "/v1/projects/scratch-project", { method: "DELETE" })).status
      ).toBe(204)
      expect(existsSync(scratchFolder)).toBe(false)
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })
})

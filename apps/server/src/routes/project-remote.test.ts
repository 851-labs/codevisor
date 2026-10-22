import { execFileSync } from "node:child_process"
import { writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest, listSubjectEvents } from "../test-support.js"
import { git, makeOrigin, startServer, tempDir } from "./project-setup-test-support.js"
import { field } from "./response-test-support.js"

const identity = {
  ...process.env,
  GIT_AUTHOR_NAME: "Test",
  GIT_AUTHOR_EMAIL: "test@example.test",
  GIT_COMMITTER_NAME: "Test",
  GIT_COMMITTER_EMAIL: "test@example.test"
}

const bareRemote = (): string => {
  const bare = join(tempDir("codevisor-remote-"), "notes.git")
  execFileSync("git", ["init", "--bare", "-b", "main", bare], { stdio: "ignore" })
  return bare
}

describe("publishing a project without a remote", () => {
  it("commits a plain folder, pushes it to the new remote and records it as the repository", async () => {
    const { server, services } = await startServer(identity)
    const folder = tempDir("codevisor-remote-notes-")
    writeFileSync(join(folder, "notes.md"), "notes\n")
    writeFileSync(join(folder, ".env"), "TOKEN=1\n")
    const created = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder }),
      method: "POST"
    })
    const projectId = String(field(created.body, "id"))
    const before = await jsonRequest(server, `/v1/projects/${projectId}/setup-source`)
    const url = `file://${bareRemote()}`

    const published = await jsonRequest(server, `/v1/projects/${projectId}/remote`, {
      body: JSON.stringify({ url, initialize: true }),
      method: "POST"
    })
    const after = await jsonRequest(server, `/v1/projects/${projectId}/setup-source`)
    const again = await jsonRequest(server, `/v1/projects/${projectId}/remote`, {
      body: JSON.stringify({ url }),
      method: "POST"
    })

    expect(before.body).toMatchObject({ needsInitialCommit: true })
    expect(published).toMatchObject({ status: 200, body: { id: projectId, repoUrl: url } })
    expect(after.body).toMatchObject({ needsInitialCommit: false })
    expect(
      listSubjectEvents(services, projectId).findLast((event) => event.kind === "project.updated")
        ?.payload
    ).toMatchObject({ repoUrl: url })
    expect(again).toMatchObject({ status: 409, body: { code: "already_exists" } })
  })

  it("rejects a malformed URL and reports unreachable remotes and rejected pushes", async () => {
    const { server } = await startServer(identity)
    const checkout = await makeOrigin()
    const created = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: checkout }),
      method: "POST"
    })
    const projectId = String(field(created.body, "id"))

    const malformed = await jsonRequest(server, `/v1/projects/${projectId}/remote`, {
      body: JSON.stringify({ url: "not a url" }),
      method: "POST"
    })
    const unreachable = await jsonRequest(server, `/v1/projects/${projectId}/remote`, {
      body: JSON.stringify({ url: "file:///nowhere/notes.git" }),
      method: "POST"
    })

    const ahead = await makeOrigin()
    await git(["commit", "--allow-empty", "-m", "ahead"], ahead)
    const populated = bareRemote()
    await git(["push", populated, "main"], ahead)
    const rejected = await jsonRequest(server, `/v1/projects/${projectId}/remote`, {
      body: JSON.stringify({ url: `file://${populated}` }),
      method: "POST"
    })

    expect(malformed).toMatchObject({ status: 400, body: { code: "invalid_url" } })
    expect(unreachable.status).toBe(422)
    expect(rejected).toMatchObject({ status: 422, body: { code: "push_rejected" } })
  })
})

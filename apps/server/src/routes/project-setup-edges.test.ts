import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
import { homedir, tmpdir } from "node:os"
import { basename, join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import { jsonRequest, listSubjectEvents, start } from "../test-support.js"
import { MAX_CLONE_FOLDER_SUFFIX } from "./project-clone.js"
import {
  fakeCli,
  git,
  makeOrigin,
  silentGitDaemon,
  startServer,
  tempDir,
  useBaseFolder
} from "./project-setup-test-support.js"
import { field } from "./response-test-support.js"

const lastSetup = (services: Parameters<typeof listSubjectEvents>[0], projectId: string) =>
  listSubjectEvents(services, projectId).findLast((event) => event.kind === "project.setup")
    ?.payload

describe("project setup sources", () => {
  it("reports a checkout that isn't a git repository as having nothing to copy", async () => {
    const { server } = await start()
    const folder = tempDir("codevisor-setup-plain-")
    writeFileSync(join(folder, ".env"), "TOKEN=1\n")
    const project = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder }),
      method: "POST"
    })
    const projectId = String(field(project.body, "id"))

    const source = await jsonRequest(server, `/v1/projects/${projectId}/setup-source`)
    rmSync(folder, { recursive: true, force: true })
    const missing = await jsonRequest(server, `/v1/projects/${projectId}/setup-source`)

    expect(source.body).toMatchObject({ envFiles: [] })
    expect(missing.status).toBe(404)
  })

  it("mirrors a home-relative path and skips links and oversized env files", async () => {
    const origin = await makeOrigin()
    const parent = tempDir(".codevisor-setup-home-", homedir())
    const checkout = join(parent, "widget")
    await git(["clone", origin, checkout], tmpdir())
    writeFileSync(join(checkout, ".env"), "TOKEN=1\n")
    writeFileSync(join(checkout, ".env.huge"), "x".repeat(1024 * 1024 + 1))
    symlinkSync(join(checkout, ".env"), join(checkout, ".env.link"))
    const { server } = await startServer()
    const project = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: checkout }),
      method: "POST"
    })

    const source = await jsonRequest(
      server,
      `/v1/projects/${String(field(project.body, "id"))}/setup-source`
    )

    expect(source.body).toMatchObject({
      homeRelativePath: join(basename(parent), "widget"),
      envFiles: [{ path: ".env", size: 8 }]
    })
  })
})

describe("project setup destinations", () => {
  it("clones into the mirrored home path, ignoring unsafe ones, and reuses projects by remote", async () => {
    const origin = await makeOrigin()
    const { server, services } = await startServer()
    const baseFolder = await useBaseFolder(server)
    const mirror = tempDir(".codevisor-setup-mirror-", homedir())
    const url = `file://${origin}`
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: tempDir("codevisor-setup-unrelated-") }),
      method: "POST"
    })

    const unsafe = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ url, name: "widget", homeRelativePath: "../escape/widget" }),
      method: "POST"
    })
    rmSync(join(baseFolder, "widget"), { recursive: true, force: true })
    const mirrored = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({
        id: "mirrored",
        url,
        name: "Widget App",
        homeRelativePath: join(basename(mirror), "widget")
      }),
      method: "POST"
    })
    const reused = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ url, envFiles: [{ path: ".env", contents: "A=1\n" }] }),
      method: "POST"
    })

    expect(unsafe.body).toMatchObject({ locations: [{ folderPath: join(baseFolder, "widget") }] })
    expect(mirrored.body).toMatchObject({
      name: "Widget App",
      locations: [{ folderPath: join(mirror, "widget") }]
    })
    expect(reused).toMatchObject({ status: 200, body: { id: "mirrored" } })
    expect(readFileSync(join(mirror, "widget", ".env"), "utf8")).toBe("A=1\n")
    expect(lastSetup(services, "mirrored")).toMatchObject({ state: "completed" })
  })

  it("adopts a later clone after skipping a repository with no remote and a plain folder", async () => {
    const origin = await makeOrigin()
    const { server } = await startServer()
    const baseFolder = await useBaseFolder(server)
    const url = `file://${origin}`
    mkdirSync(join(baseFolder, "widget"))
    await git(["init"], join(baseFolder, "widget"))
    mkdirSync(join(baseFolder, "widget-2"))
    await git(["clone", url, join(baseFolder, "widget-3")], tmpdir())
    writeFileSync(join(baseFolder, "widget-3", ".env"), "EXISTING=1\n")

    const adopted = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ url, envFiles: [{ path: ".env", contents: "NEW=1\n" }] }),
      method: "POST"
    })

    expect(adopted).toMatchObject({
      status: 201,
      body: { locations: [{ folderPath: join(baseFolder, "widget-3") }] }
    })
    expect(readFileSync(join(baseFolder, "widget-3", ".env"), "utf8")).toBe("EXISTING=1\n")
  })

  it("gives up when every candidate folder is taken", async () => {
    const origin = await makeOrigin()
    const { server, services } = await startServer()
    const baseFolder = await useBaseFolder(server)
    mkdirSync(join(baseFolder, "widget"))
    for (let suffix = 2; suffix <= MAX_CLONE_FOLDER_SUFFIX; suffix += 1) {
      mkdirSync(join(baseFolder, `widget-${String(suffix)}`))
    }

    const taken = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ id: "taken", url: `file://${origin}` }),
      method: "POST"
    })

    expect(taken).toMatchObject({ status: 409, body: { code: "already_exists" } })
    expect(lastSetup(services, "taken")).toMatchObject({ state: "failed", code: "already_exists" })
  })

  it("rejects env files that aren't env files, are too large, or escape the folder", async () => {
    const origin = await makeOrigin()
    const outside = tempDir("codevisor-setup-outside-")
    symlinkSync(outside, join(origin, "linked"))
    await git(["add", "linked"], origin)
    await git(["commit", "-m", "link"], origin)
    const { server, services } = await startServer()
    const baseFolder = await useBaseFolder(server)
    const url = `file://${origin}`

    const request = (path: string, contents: string) =>
      jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "escape", url, envFiles: [{ path, contents }] }),
        method: "POST"
      })

    expect((await request("README.md", "x")).status).toBe(400)
    expect(await request("../.env", "X=1")).toMatchObject({
      status: 400,
      body: { error: "Not an env file path: ../.env" }
    })
    expect((await request(".env", "x".repeat(1024 * 1024 + 1))).status).toBe(400)
    expect((await request("linked/.env", "SECRET=1")).status).toBe(400)
    expect(existsSync(join(outside, ".env"))).toBe(false)
    expect(existsSync(join(baseFolder, "widget"))).toBe(false)
    expect(lastSetup(services, "escape")).toMatchObject({ state: "failed" })
  })
})

describe("project setup transport", () => {
  it("falls back to SSH when HTTPS can't be reached", async () => {
    const origin = await makeOrigin()
    const bare = join(tempDir("codevisor-setup-bare-"), "widget.git")
    await git(["clone", "--bare", origin, bare], tmpdir())
    const env = fakeCli("fake-ssh", 'for last; do :; done\ncd / && exec sh -c "$last"')
    const sshEnv = { ...env, GIT_SSH_COMMAND: "fake-ssh" }
    const { server, services } = await startServer(sshEnv)
    await useBaseFolder(server)
    const https = `https://localhost${bare}`

    const cloned = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ url: https }),
      method: "POST"
    })
    const missing = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ id: "missing-ssh", url: "https://localhost/nowhere/widget.git" }),
      method: "POST"
    })

    expect(cloned).toMatchObject({
      status: 201,
      body: { repoUrl: `git@localhost:${bare.slice(1)}` }
    })
    expect(missing.status).toBe(422)
    expect(lastSetup(services, "missing-ssh")).toMatchObject({
      state: "failed",
      host: "localhost"
    })
  })

  it("reports the more telling failure when both transports fail and logs each without credentials", async () => {
    const env = fakeCli("fake-ssh", 'echo "ERROR: Repository not found." >&2\nexit 1')
    const { server, services } = await startServer({ ...env, GIT_SSH_COMMAND: "fake-ssh" })
    await useBaseFolder(server)
    const logged = vi.spyOn(console, "error").mockImplementation(() => undefined)
    onTestFinished(() => logged.mockRestore())

    const failed = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({
        id: "gone",
        url: "https://cv:ghp_cv3074secret@localhost/acme/gone.git"
      }),
      method: "POST"
    })

    expect(failed).toMatchObject({ status: 422, body: { code: "repo_not_found" } })
    expect(lastSetup(services, "gone")).toMatchObject({ state: "failed", code: "repo_not_found" })
    const lines = logged.mock.calls.map(([line]) => String(line))
    expect(lines.map((line) => JSON.parse(line) as unknown)).toEqual([
      expect.objectContaining({
        event: "project_clone_failed",
        host: "localhost",
        scheme: "https"
      }),
      expect.objectContaining({
        event: "project_clone_failed",
        code: "repo_not_found",
        host: "localhost",
        scheme: "ssh",
        stderr: expect.stringContaining("ERROR: Repository not found.")
      })
    ])
    expect(lines.join("\n")).not.toContain("cv3074secret")
  })

  it("logs a clone that fails after the remote answered", async () => {
    const origin = await makeOrigin()
    const objects = join(origin, ".git", "objects")
    for (const entry of readdirSync(objects).filter((name) => /^[0-9a-f]{2}$/.test(name))) {
      rmSync(join(objects, entry), { recursive: true })
    }
    const { server, services } = await startServer()
    await useBaseFolder(server)
    const logged = vi.spyOn(console, "error").mockImplementation(() => undefined)
    onTestFinished(() => logged.mockRestore())

    const failed = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ id: "hollow", url: `file://${origin}` }),
      method: "POST"
    })

    expect(failed.status).toBe(422)
    expect(lastSetup(services, "hollow")).toMatchObject({ state: "failed" })
    expect(logged.mock.calls.map(([line]) => JSON.parse(String(line)) as unknown)).toEqual([
      expect.objectContaining({
        event: "project_clone_failed",
        scheme: "file",
        stderr: expect.stringContaining("not our ref")
      })
    ])
  })

  it("cancels a setup in progress and refuses a second one for the same repository", async () => {
    const { url, connected } = await silentGitDaemon()
    const { server, services } = await startServer()
    await useBaseFolder(server)

    const first = jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ id: "slow-setup", url }),
      method: "POST"
    })
    await connected
    const second = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ url }),
      method: "POST"
    })
    const cancelled = await jsonRequest(server, "/v1/projects/from-git/slow-setup", {
      method: "DELETE"
    })

    expect(second).toMatchObject({ status: 409, body: { code: "in_progress" } })
    expect(cancelled.status).toBe(204)
    expect(await first).toMatchObject({ status: 422, body: { code: "cancelled" } })
    expect(lastSetup(services, "slow-setup")).toMatchObject({ state: "failed", code: "cancelled" })
    const again = await jsonRequest(server, "/v1/projects/from-git/slow-setup", {
      method: "DELETE"
    })
    expect(again.status).toBe(404)
  })
})

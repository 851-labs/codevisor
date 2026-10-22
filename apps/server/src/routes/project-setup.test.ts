import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest, listSubjectEvents } from "../test-support.js"
import {
  fakeCli,
  git,
  makeOrigin,
  startServer,
  tempDir,
  useBaseFolder
} from "./project-setup-test-support.js"
import { field } from "./response-test-support.js"

describe("project setup on another machine", () => {
  it("lists the source checkout's untracked env files and reads them back", async () => {
    const origin = await makeOrigin()
    const checkout = join(tempDir("codevisor-setup-source-"), "widget")
    await git(["clone", origin, checkout], tmpdir())
    writeFileSync(join(checkout, ".env"), "TOKEN=1\n")
    writeFileSync(join(checkout, "apps", "web", ".env.local"), "LOCAL=1\n")
    writeFileSync(join(checkout, "apps", "web", ".dev.vars"), "VARS=1\n")
    mkdirSync(join(checkout, "node_modules", "pkg"), { recursive: true })
    writeFileSync(join(checkout, "node_modules", "pkg", ".env"), "IGNORED=1\n")
    const { server } = await startServer()
    const project = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: checkout }),
      method: "POST"
    })
    const projectId = String(field(project.body, "id"))

    const source = await jsonRequest(server, `/v1/projects/${projectId}/setup-source`)

    expect(source.body).toMatchObject({
      folderPath: checkout,
      envFiles: [
        { path: ".env", size: 8 },
        { path: "apps/web/.dev.vars", size: 7 },
        { path: "apps/web/.env.local", size: 8 }
      ]
    })
    const read = await jsonRequest(server, `/v1/projects/${projectId}/env-files/read`, {
      body: JSON.stringify({ paths: [".env", "apps/web/.env.local"] }),
      method: "POST"
    })
    expect(read.body).toEqual({
      files: [
        { path: ".env", contents: "TOKEN=1\n" },
        { path: "apps/web/.env.local", contents: "LOCAL=1\n" }
      ]
    })
    const outside = await jsonRequest(server, `/v1/projects/${projectId}/env-files/read`, {
      body: JSON.stringify({ paths: ["README.md"] }),
      method: "POST"
    })
    expect(outside.status).toBe(400)
  })

  it("clones with env files and the repository's settings, then reuses the project", async () => {
    const origin = await makeOrigin()
    const { server, services } = await startServer()
    const baseFolder = await useBaseFolder(server)
    const url = `file://${origin}`

    const created = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({
        id: "setup-project",
        url,
        envFiles: [
          { path: ".env", contents: "TOKEN=1\n" },
          { path: "apps/web/.env.local", contents: "LOCAL=1\n" }
        ],
        worktreeBase: { remote: "origin", branch: "develop" },
        defaultRunLocation: "newWorktree"
      }),
      method: "POST"
    })

    const folder = join(baseFolder, "widget")
    expect(created).toMatchObject({
      status: 201,
      body: {
        id: "setup-project",
        locations: [{ folderPath: folder }],
        worktreeBase: { remote: "origin", branch: "develop" },
        defaultRunLocation: "newWorktree"
      }
    })
    expect(readFileSync(join(folder, "apps", "web", ".env.local"), "utf8")).toBe("LOCAL=1\n")
    expect(statSync(join(folder, ".env")).mode & 0o777).toBe(0o600)
    const updates = listSubjectEvents(services, "setup-project")
      .filter((event) => event.kind === "project.setup")
      .map((event) => event.payload)
    expect(updates.at(0)).toMatchObject({ state: "started" })
    expect(updates).toContainEqual(
      expect.objectContaining({ state: "progress", progress: { stage: "copying" } })
    )
    expect(updates.at(-1)).toMatchObject({ state: "completed", folderPath: folder })

    const again = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ id: "second-attempt", url }),
      method: "POST"
    })
    expect(again).toMatchObject({ status: 200, body: { id: "setup-project" } })
    expect(listSubjectEvents(services, "second-attempt").at(-1)).toMatchObject({
      kind: "project.setup",
      payload: { state: "completed", folderPath: folder }
    })
  })

  it("adopts an existing clone of the repository and skips unrelated folders", async () => {
    const origin = await makeOrigin()
    const { server } = await startServer()
    const baseFolder = await useBaseFolder(server)
    const url = `file://${origin}`
    mkdirSync(join(baseFolder, "widget"))
    writeFileSync(join(baseFolder, "widget", "unrelated.txt"), "keep me")
    await git(["clone", url, join(baseFolder, "widget-2")], tmpdir())
    writeFileSync(join(baseFolder, "widget-2", ".env"), "EXISTING=1\n")

    const adopted = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({ url, envFiles: [{ path: ".env", contents: "NEW=1\n" }] }),
      method: "POST"
    })

    expect(adopted).toMatchObject({
      status: 201,
      body: { locations: [{ folderPath: join(baseFolder, "widget-2") }] }
    })
    expect(readFileSync(join(baseFolder, "widget-2", ".env"), "utf8")).toBe("EXISTING=1\n")
    expect(readFileSync(join(baseFolder, "widget", "unrelated.txt"), "utf8")).toBe("keep me")
  })

  it("rejects env file paths that leave the project folder before cloning", async () => {
    const origin = await makeOrigin()
    const { server } = await startServer()
    const baseFolder = await useBaseFolder(server)

    const escaped = await jsonRequest(server, "/v1/projects/from-git", {
      body: JSON.stringify({
        url: `file://${origin}`,
        envFiles: [{ path: "../.env", contents: "X=1" }]
      }),
      method: "POST"
    })

    expect(escaped.status).toBe(400)
    expect(existsSync(join(baseFolder, "widget"))).toBe(false)
  })

  it("expands, validates, and resets the clone base folder", async () => {
    const { server } = await startServer()
    const put = (baseFolder: string | null) =>
      jsonRequest(server, "/v1/projects/clone-settings", {
        body: JSON.stringify({ baseFolder }),
        method: "PUT"
      })

    const initial = await jsonRequest(server, "/v1/projects/clone-settings")
    const home = await put("~")
    const nested = await put("~/src/")
    const relative = await put("src")
    const cleared = await put("  ")
    const defaulted = await put(String(field(cleared.body, "defaultBaseFolder")))
    await put("/tmp/elsewhere")
    const reset = await put(null)

    expect(field(initial.body, "baseFolder")).toBe(field(initial.body, "defaultBaseFolder"))
    expect(field(home.body, "baseFolder")).toBe(homedir())
    expect(field(nested.body, "baseFolder")).toBe(join(homedir(), "src"))
    expect(relative.status).toBe(400)
    expect(field(cleared.body, "baseFolder")).toBe(field(cleared.body, "defaultBaseFolder"))
    expect(field(defaulted.body, "baseFolder")).toBe(field(defaulted.body, "defaultBaseFolder"))
    expect(field(reset.body, "baseFolder")).toBe(field(reset.body, "defaultBaseFolder"))
  })

  it("answers only known git sign-in routes", async () => {
    const { server } = await startServer()

    const noHost = await jsonRequest(server, "/v1/git/auth/status")
    const unknownFlow = await jsonRequest(server, "/v1/git/auth/login/nope")
    const unknownCancel = await jsonRequest(server, "/v1/git/auth/login/nope", {
      method: "DELETE"
    })
    const wrongVerb = await jsonRequest(server, "/v1/git/auth/login/nope", {
      body: "{}",
      method: "PUT"
    })
    const unknownRoute = await jsonRequest(server, "/v1/git/auth/other")

    expect(noHost.status).toBe(400)
    expect(unknownFlow.status).toBe(404)
    expect(unknownCancel.status).toBe(404)
    expect(wrongVerb.status).toBe(404)
    expect(unknownRoute.status).toBe(404)
  })
})

describe("git sign-in", () => {
  it("relays the device code and finishes once the CLI signs in", async () => {
    const marker = join(tempDir("codevisor-gh-marker-"), "approved")
    const env = fakeCli(
      "gh",
      `
case "$1 $2" in
  "auth status") [ -f "${marker}" ] && echo "Logged in to github.com account octocat" && exit 0; exit 1 ;;
  "auth setup-git") exit 0 ;;
  "auth login")
    echo "! First copy your one-time code: AB12-CD34" >&2
    echo "Open this URL to continue in your web browser: https://github.com/login/device" >&2
    read line
    while [ ! -f "${marker}.go" ]; do sleep 0.05; done
    touch "${marker}"
    exit 0 ;;
esac`
    )
    const { server } = await startServer(env)

    const before = await jsonRequest(server, "/v1/git/auth/status?host=github.com")
    const started = await jsonRequest(server, "/v1/git/auth/login", {
      body: JSON.stringify({ host: "github.com" }),
      method: "POST"
    })

    expect(before.body).toMatchObject({ provider: "github", cliInstalled: true, signedIn: false })
    expect(started.body).toMatchObject({
      state: "waiting",
      userCode: "AB12-CD34",
      verificationUrl: "https://github.com/login/device"
    })
    writeFileSync(`${marker}.go`, "")
    const flowId = String(field(started.body, "id"))
    let flow = await jsonRequest(server, `/v1/git/auth/login/${flowId}`)
    while (field(flow.body, "state") === "waiting") {
      await new Promise((resolve) => setTimeout(resolve, 20))
      flow = await jsonRequest(server, `/v1/git/auth/login/${flowId}`)
    }
    expect(flow.body).toMatchObject({ state: "complete", account: "octocat" })
  })

  it("reports a missing CLI and unsupported hosts", async () => {
    const { server } = await startServer({ ...process.env, PATH: tempDir("codevisor-empty-bin-") })

    const github = await jsonRequest(server, "/v1/git/auth/status?host=github.com")
    const bitbucket = await jsonRequest(server, "/v1/git/auth/status?host=bitbucket.org")
    const login = await jsonRequest(server, "/v1/git/auth/login", {
      body: JSON.stringify({ host: "bitbucket.org" }),
      method: "POST"
    })

    expect(github.body).toMatchObject({ cliInstalled: false, supported: true, signedIn: false })
    expect(bitbucket.body).toMatchObject({ provider: "bitbucket", supported: false })
    expect(login.status).toBe(400)
  })

  it("cancels a pending sign-in", async () => {
    const env = fakeCli(
      "gh",
      `
echo "First copy your one-time code: AB12-CD34"
echo "https://github.com/login/device"
exec sleep 30`
    )
    const { server } = await startServer(env)
    const started = await jsonRequest(server, "/v1/git/auth/login", {
      body: JSON.stringify({ host: "github.com" }),
      method: "POST"
    })
    const flowId = String(field(started.body, "id"))

    const cancelled = await jsonRequest(server, `/v1/git/auth/login/${flowId}`, {
      method: "DELETE"
    })
    const flow = await jsonRequest(server, `/v1/git/auth/login/${flowId}`)

    expect(cancelled.status).toBe(204)
    expect(flow.body).toMatchObject({ state: "cancelled" })
  })
})

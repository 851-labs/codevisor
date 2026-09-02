import type { McpServer } from "@codevisor/api"
import { createServer } from "node:http"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import { jsonRequest, run, runningServers, start, startWithApp, tempDirs } from "../test-support.js"

describe("mcp installation routes", () => {
  it("detects MCP authorization challenges", async () => {
    const detector = createServer((request, response) => {
      if (request.url === "/oauth") {
        response.writeHead(401, {
          "www-authenticate": 'Bearer resource_metadata="https://auth.example.test/resource"'
        })
      } else if (request.url === "/bearer") {
        response.writeHead(401, { "www-authenticate": "Bearer" })
      } else if (request.url === "/metadata") {
        response.writeHead(401)
      } else if (request.url === "/required") {
        response.writeHead(401)
      } else if (request.url === "/.well-known/oauth-protected-resource/metadata") {
        response.writeHead(200, { "content-type": "application/json" })
        response.end(
          JSON.stringify({
            authorization_servers: ["https://auth.example.test"],
            resource: `http://${request.headers.host}/metadata`
          })
        )
        return
      } else if (request.url?.startsWith("/.well-known/")) {
        response.writeHead(404)
      } else {
        response.writeHead(200, { "content-type": "application/json" })
      }
      response.end("{}")
    })
    await new Promise<void>((resolve) => detector.listen(0, "127.0.0.1", resolve))
    const address = detector.address()
    if (address === null || typeof address === "string") throw new Error("Missing detector port")
    const { server } = await start()
    try {
      for (const [path, authType] of [
        ["none", "none"],
        ["bearer", "bearer"],
        ["metadata", "oauth"],
        ["required", "bearer"],
        ["oauth", "oauth"]
      ] as const) {
        const detected = await jsonRequest(server, "/v1/mcps/detect-auth", {
          method: "POST",
          body: JSON.stringify({ url: `http://127.0.0.1:${address.port}/${path}` })
        })
        expect(detected.status).toBe(200)
        expect(detected.body).toMatchObject({ authType })
      }
      const created = await jsonRequest(server, "/v1/mcps", {
        method: "POST",
        body: JSON.stringify({
          enabled: false,
          name: "Auto OAuth",
          transport: "http",
          url: `http://127.0.0.1:${address.port}/oauth`
        })
      })
      expect(created.status).toBe(201)
      expect(created.body).toMatchObject({
        authType: "oauth",
        connectionState: "needsAuthorization",
        enabled: false
      })
    } finally {
      await new Promise<void>((resolve, reject) =>
        detector.close((error) => (error === undefined ? resolve() : reject(error)))
      )
    }
  })

  it("manages MCP installations without returning encrypted credentials", async () => {
    const { agents, server, services } = await start()
    const created = await jsonRequest(server, "/v1/mcps", {
      method: "POST",
      body: JSON.stringify({
        authType: "bearer",
        bearerToken: "secret-token",
        headers: { "X-Workspace": "emojis", Authorization: "secret-header" },
        enabled: false,
        name: "Example",
        transport: "http",
        url: "https://example.test/mcp"
      })
    })
    expect(created.status).toBe(201)
    expect(created.body).toMatchObject({
      authType: "bearer",
      enabled: false,
      name: "Example"
    })
    expect(JSON.stringify(created.body)).not.toContain("secret-token")
    expect(created.body).toMatchObject({ headerNames: ["Authorization", "X-Workspace"] })
    expect(JSON.stringify(created.body)).not.toContain("secret-header")
    expect(JSON.stringify(created.body)).not.toContain("secretCipher")

    const id = (created.body as { id: string }).id
    const updated = await jsonRequest(server, `/v1/mcps/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ name: "Renamed" })
    })
    expect(updated.status).toBe(200)
    expect(updated.body).toMatchObject({ enabled: false, name: "Renamed" })

    const listed = await jsonRequest(server, "/v1/mcps")
    expect(listed.body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id, kind: "managed", name: "Renamed" }),
        expect.objectContaining({ id: "browser", canRemove: false, kind: "browserUse" }),
        expect.objectContaining({ id: "computer", canEdit: false, kind: "computerUse" })
      ])
    )
    expect((await jsonRequest(server, "/v1/mcps/browser", { method: "DELETE" })).status).toBe(409)
    expect(
      (
        await jsonRequest(server, "/v1/mcps/computer", {
          method: "PATCH",
          body: JSON.stringify({ name: "Renamed" })
        })
      ).status
    ).toBe(409)
    expect(
      (
        await jsonRequest(server, "/v1/mcps/computer", {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)

    expect((await jsonRequest(server, `/v1/mcps/${id}`, { method: "DELETE" })).status).toBe(204)

    const local = await jsonRequest(server, "/v1/mcps", {
      method: "POST",
      body: JSON.stringify({
        authType: "none",
        command: "missing-local-mcp",
        enabled: false,
        env: { API_KEY: "local-secret", REGION: "us-west" },
        name: "Local",
        transport: "stdio"
      })
    })
    expect(local.status).toBe(201)
    expect(local.body).toMatchObject({ environmentNames: ["API_KEY", "REGION"] })
    expect(JSON.stringify(local.body)).not.toContain("local-secret")
    const localId = (local.body as { id: string }).id
    const changedLocal = await jsonRequest(server, `/v1/mcps/${localId}`, {
      method: "PATCH",
      body: JSON.stringify({ env: { ACCOUNT: "new-secret" }, removeEnv: ["REGION"] })
    })
    expect(changedLocal.body).toMatchObject({ environmentNames: ["ACCOUNT", "API_KEY"] })
    expect(JSON.stringify(changedLocal.body)).not.toContain("new-secret")

    const scopedProjectFolder = mkdtempSync(join(tmpdir(), "codevisor-mcp-route-scope-"))
    tempDirs.push(scopedProjectFolder)
    const project = await run(services.db.createProject({ folderPath: scopedProjectFolder }))
    const session = await run(
      services.db.createSession({ harnessId: "codex", projectId: project.id, title: "Scoped" })
    )
    expect(
      (
        await jsonRequest(server, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)

    const publicLocal = local.body as McpServer
    vi.spyOn(services.mcp, "connect").mockResolvedValue(publicLocal)
    vi.spyOn(services.mcp, "tools").mockResolvedValue([])
    vi.spyOn(services.mcp, "beginOAuth").mockResolvedValue("https://example.test/authorize")
    vi.spyOn(services.mcp, "disconnectOAuth").mockResolvedValue(publicLocal)
    const finishOAuth = vi.spyOn(services.mcp, "finishOAuth").mockResolvedValue(publicLocal)
    expect((await jsonRequest(server, `/v1/mcps/${localId}/tools`)).status).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/connect`, { method: "POST" })).status
    ).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/oauth-start`, { method: "POST" })).status
    ).toBe(201)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/oauth-disconnect`, { method: "POST" })).status
    ).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/unknown`, { method: "POST" })).status
    ).toBe(404)
    expect((await jsonRequest(server, "/v1/mcps", { method: "PUT" })).status).toBe(404)
    expect((await jsonRequest(server, `/v1/mcps/${localId}`)).status).toBe(404)
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/callback?state=state-1&code=code-1`).then(
        (response) => response.status
      )
    ).toBe(200)
    expect(finishOAuth).toHaveBeenCalledWith("state-1", "code-1")
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/callback?state=state-1`).then(
        (response) => response.status
      )
    ).toBe(400)
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/complete`).then((response) => response.status)
    ).toBe(200)

    expect((await jsonRequest(server, `/v1/mcps/${localId}`, { method: "DELETE" })).status).toBe(
      204
    )
    expect(
      ((await jsonRequest(server, "/v1/mcps")).body as ReadonlyArray<McpServer>).map(
        (candidate) => candidate.id
      )
    ).toEqual(["browser", "computer"])

    const automationAnswer = vi.spyOn(services.mcp, "answerQuestion").mockResolvedValueOnce(true)
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/questions/automation-question/answer`,
          {
            method: "POST",
            body: JSON.stringify({ outcome: "cancelled" })
          }
        )
      ).status
    ).toBe(202)
    expect(automationAnswer).toHaveBeenCalledWith(session.id, "automation-question", {
      outcome: "cancelled"
    })
    expect(agents.questionAnswers).toEqual([])

    const { mcp: _mcp, ...withoutMcp } = services
    const unavailable = await startWithApp(withoutMcp)
    runningServers.push(unavailable)
    expect((await jsonRequest(unavailable, "/v1/mcps")).status).toBe(501)
    expect(
      (
        await jsonRequest(unavailable, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(501)
    expect(
      (
        await jsonRequest(unavailable, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(501)
    expect(
      await fetch(`${unavailable.url}/mcp/gateway`, { method: "POST" }).then((r) => r.status)
    ).toBe(501)
    const unavailableAnswer = await jsonRequest(
      unavailable,
      `/v1/sessions/${session.id}/questions/no-mcp-question/answer`,
      {
        method: "POST",
        body: JSON.stringify({ outcome: "cancelled" })
      }
    )
    expect(unavailableAnswer.status, JSON.stringify(unavailableAnswer.body)).toBe(202)
    expect(agents.questionAnswers.at(-1)).toEqual([
      expect.any(String),
      "no-mcp-question",
      { outcome: "cancelled" }
    ])
    expect(
      await fetch(`${unavailable.url}/v1/mcps/oauth/callback?state=x&code=y`).then(
        (response) => response.status
      )
    ).toBe(501)
  })
})

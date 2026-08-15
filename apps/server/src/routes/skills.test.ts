import { describe, expect, it } from "vitest"
import { SkillsError } from "@codevisor/skills"
import {
  jsonRequest,
  makeServices,
  runningServers,
  skillsStub,
  startWithApp
} from "../test-support.js"

describe("skills routes", () => {
  it("routes skills CRUD operations to the manager", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<unknown[]> = []
    const server = await startWithApp({ ...services, skills: skillsStub(calls) })
    runningServers.push(server)

    expect(
      (
        await jsonRequest(server, "/v1/skills", {
          body: JSON.stringify({ description: "Deploy checklist", name: "Deploy" }),
          method: "POST"
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/skills/import", {
          body: JSON.stringify({ path: "/tmp/deploy" }),
          method: "POST"
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/skills/import-remote", {
          body: JSON.stringify({ source: "vercel-labs/skills" }),
          method: "POST"
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/skills/make-global", {
          body: JSON.stringify({ directoryName: "ship-it", harnessId: "claude-code" }),
          method: "POST"
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, "/v1/skills/sync", {
          body: JSON.stringify({}),
          method: "POST"
        })
      ).status
    ).toBe(200)
    const discovered = await jsonRequest(server, "/v1/skills/discover-remote", {
      body: JSON.stringify({ source: "vercel-labs/skills" }),
      method: "POST"
    })
    expect(discovered.status).toBe(200)
    expect(discovered.body).toEqual({
      skills: [{ alreadyExists: false, directoryName: "deploy", name: "Deploy" }]
    })
    expect(
      (
        await jsonRequest(server, "/v1/skills/deploy/harnesses/claude-code", {
          body: JSON.stringify({ installed: true }),
          method: "PUT"
        })
      ).status
    ).toBe(200)
    expect((await jsonRequest(server, "/v1/skills/deploy", { method: "DELETE" })).status).toBe(200)

    expect(calls).toEqual([
      ["create", { description: "Deploy checklist", name: "Deploy" }],
      ["importLocal", { path: "/tmp/deploy" }],
      ["importRemote", { source: "vercel-labs/skills" }],
      ["makeGlobal", "claude-code", "ship-it"],
      ["sync", {}],
      ["discoverRemote", { source: "vercel-labs/skills" }],
      ["setInstalled", "deploy", "claude-code", true],
      ["remove", "deploy"]
    ])
  })

  it("maps SkillsError codes onto HTTP statuses", async () => {
    const { services } = await makeServices("server-a")
    const failing = {
      ...skillsStub([]),
      create: async () => {
        throw new SkillsError("already exists", "conflict")
      },
      importLocal: async () => {
        throw new SkillsError("not a directory", "invalid")
      },
      remove: async () => {
        throw new SkillsError("no such skill", "notFound")
      }
    }
    const server = await startWithApp({ ...services, skills: failing })
    runningServers.push(server)

    const conflict = await jsonRequest(server, "/v1/skills", {
      body: JSON.stringify({ description: "", name: "deploy" }),
      method: "POST"
    })
    expect(conflict.status).toBe(409)
    expect(conflict.body).toEqual({ code: "conflict", error: "already exists" })
    expect(
      (
        await jsonRequest(server, "/v1/skills/import", {
          body: JSON.stringify({ path: "/tmp/nope" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    expect((await jsonRequest(server, "/v1/skills/deploy", { method: "DELETE" })).status).toBe(404)
  })
})

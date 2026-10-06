import { SkillsError } from "@codevisor/skills"
import { describe, expect, it } from "vitest"

import {
  jsonRequest,
  makeServices,
  runningServers,
  skillsStub,
  startWithApp
} from "../test-support.js"

describe("skills routes", () => {
  it("reads and updates a named skill and rejects invalid update bodies", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<unknown[]> = []
    const server = await startWithApp({ ...services, skills: skillsStub(calls) })
    runningServers.push(server)

    const read = await jsonRequest(server, "/v1/skills/deploy")
    expect(read.status).toBe(200)
    expect(read.body).toEqual({
      content: "---\nname: Deploy\ndescription: Deploy checklist\n---\nShip it.\n"
    })
    const content = "---\nname: Deploy\ndescription: Updated checklist\n---\nReview, then ship.\n"
    const updated = await jsonRequest(server, "/v1/skills/deploy", {
      method: "PUT",
      body: JSON.stringify({ content })
    })
    expect(updated.status).toBe(200)
    expect(updated.body).toHaveProperty("skills")
    const invalid = await jsonRequest(server, "/v1/skills/deploy", {
      method: "PUT",
      body: JSON.stringify({ content: 123 })
    })
    expect(invalid.status).toBe(400)
    expect(calls).toEqual([
      ["read", "deploy"],
      ["update", "deploy", { content }]
    ])
  })

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
        await jsonRequest(server, "/v1/skills/import-remote", {
          body: JSON.stringify({ source: "vercel-labs/skills" }),
          method: "POST"
        })
      ).status
    ).toBe(201)
    const discovered = await jsonRequest(server, "/v1/skills/discover-remote", {
      body: JSON.stringify({ source: "vercel-labs/skills" }),
      method: "POST"
    })
    expect(discovered.status).toBe(200)
    expect(discovered.body).toEqual({
      skills: [{ alreadyExists: false, directoryName: "deploy", name: "Deploy" }]
    })
    expect((await jsonRequest(server, "/v1/skills/deploy", { method: "DELETE" })).status).toBe(200)

    expect(calls).toEqual([
      ["create", { description: "Deploy checklist", name: "Deploy" }],
      ["importRemote", { source: "vercel-labs/skills" }],
      ["discoverRemote", { source: "vercel-labs/skills" }],
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
      importRemote: async () => {
        throw new SkillsError("not a skill source", "invalid")
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
        await jsonRequest(server, "/v1/skills/import-remote", {
          body: JSON.stringify({ source: "nope" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    expect((await jsonRequest(server, "/v1/skills/deploy", { method: "DELETE" })).status).toBe(404)
  })
})

import { SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

const write = { authorization: "Bearer write-token" }
const read = { authorization: "Bearer read-token" }

const artifactUrl = (hash: string, team = "codevisor") =>
  `https://turbo-cache.test/v8/artifacts/${hash}?slug=${team}`

const bodyText = async (response: Response) =>
  new TextDecoder().decode(await response.arrayBuffer())

const upload = (hash: string, body: string, headers: Record<string, string>, team?: string) =>
  SELF.fetch(artifactUrl(hash, team), {
    method: "PUT",
    headers: { ...headers, "content-length": String(body.length), "x-artifact-duration": "1234" },
    body
  })

describe("turbo remote cache", () => {
  it("returns an uploaded artifact and its metadata to a reader", async () => {
    expect((await upload("abc123", "artifact bytes", write)).status).toBe(202)

    const fetched = await SELF.fetch(artifactUrl("abc123"), { headers: read })
    expect(fetched.status).toBe(200)
    expect(fetched.headers.get("x-artifact-duration")).toBe("1234")
    expect(await bodyText(fetched)).toBe("artifact bytes")

    const described = await SELF.fetch(artifactUrl("abc123"), { method: "HEAD", headers: read })
    expect(described.status).toBe(200)
    const missing = await SELF.fetch(artifactUrl("def456"), { method: "HEAD", headers: read })
    expect(missing.status).toBe(404)
  })

  it("ignores uploads from the read-only token and requires a token to read", async () => {
    expect((await upload("readonly", "poisoned", read)).status).toBe(202)
    expect((await SELF.fetch(artifactUrl("readonly"), { headers: read })).status).toBe(404)
    expect((await SELF.fetch(artifactUrl("abc123"))).status).toBe(401)
    expect((await upload("anonymous", "poisoned", {})).status).toBe(401)
    expect(
      (await SELF.fetch("https://turbo-cache.test/v8/artifacts/status", { headers: read })).status
    ).toBe(200)
  })

  it("keeps each team's artifacts separate", async () => {
    await upload("shared", "team a", write, "team-a")
    await upload("shared", "team b", write, "team-b")

    const teamA = await SELF.fetch(artifactUrl("shared", "team-a"), { headers: read })
    expect(await bodyText(teamA)).toBe("team a")
  })
})

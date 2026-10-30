import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  antigravityAuthPath,
  parseAntigravityAuth,
  removeAntigravityAuth,
  writeAntigravityAuth
} from "./antigravity-credentials.js"
import { readNativeOAuth } from "./shared-oauth-providers.js"

const exec = async () => ({ stdout: "", stderr: "" })
const roots: Array<string> = []
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })))
})
const profile = async () => {
  const root = await mkdtemp(join(tmpdir(), "agy-credentials-"))
  roots.push(root)
  return join(root, "profile")
}

const idToken = (claims: unknown) =>
  `header.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.signature`
const document = (
  refresh: string,
  access = "ya29.a",
  claims: unknown = { email: "Dev@Example.com" }
) => ({
  token: {
    access_token: access,
    token_type: "Bearer",
    refresh_token: refresh,
    expiry: "2026-10-13T19:14:00Z"
  },
  auth_method: "consumer",
  id_token: idToken(claims)
})

describe("Antigravity credentials", () => {
  it("shares a sign-in as its Google account, carrying the whole token file", () => {
    const bundle = parseAntigravityAuth(document("1//r"), "managed")!
    expect(bundle).toEqual({
      harnessId: "antigravity",
      subject: expect.stringMatching(/^google:[0-9a-f]{64}$/),
      accessToken: "1//r",
      expiresAt: Number.MAX_SAFE_INTEGER,
      ownership: "managed",
      email: "Dev@Example.com",
      credential: { document: document("1//r") }
    })
    const again = parseAntigravityAuth(
      document("1//other", "ya29.b", { email: "dev@example.com" }),
      "managed"
    )!
    expect(again.subject).toBe(bundle.subject)
  })

  it("names an account by its grant when the ID token says nothing usable", () => {
    const subjects = new Set<string>()
    for (const id_token of [undefined, "no-dots", "header.!!!.sig", idToken({ sub: "1" })]) {
      const bundle = parseAntigravityAuth({ ...document("1//r"), id_token }, "external")!
      expect(bundle).not.toHaveProperty("email")
      expect(bundle.ownership).toBe("external")
      subjects.add(bundle.subject)
    }
    const otherGrant = parseAntigravityAuth(
      { ...document("1//other"), id_token: undefined },
      "external"
    )!
    expect(subjects.size).toBe(1)
    expect(subjects.has(otherGrant.subject)).toBe(false)
    expect(parseAntigravityAuth({ token: { access_token: "ya29" } }, "managed")).toBeUndefined()
    expect(parseAntigravityAuth("nonsense", "managed")).toBeUndefined()
  })

  it("writes a synced grant once, leaving the access token agy refreshed since", async () => {
    const path = antigravityAuthPath(await profile())
    const first = parseAntigravityAuth(document("1//r"), "managed")!
    const root = path.slice(0, path.indexOf("/gemini/"))
    await writeAntigravityAuth(root, first)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(document("1//r"))
    expect((await stat(path)).mode & 0o777).toBe(0o600)

    await writeFile(path, JSON.stringify(document("1//r", "ya29.refreshed")))
    await writeAntigravityAuth(root, first)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(document("1//r", "ya29.refreshed"))

    await writeAntigravityAuth(root, parseAntigravityAuth(document("1//new"), "managed")!)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(document("1//new"))
    await writeFile(path, "{broken")
    await writeAntigravityAuth(root, first)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(document("1//r"))

    await removeAntigravityAuth(root)
    await expect(stat(path)).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("discovers a managed profile's sign-in, never the user's own agy", async () => {
    const root = await profile()
    const read = (isDefault: boolean) =>
      readNativeOAuth({
        harnessId: "antigravity",
        directory: root,
        isDefault,
        ownership: "managed",
        env: { GEMINI_API_KEY: "AIza" },
        exec
      })
    await expect(read(false)).resolves.toBeUndefined()
    await writeAntigravityAuth(root, parseAntigravityAuth(document("1//r"), "managed")!)
    await expect(read(false)).resolves.toMatchObject({
      harnessId: "antigravity",
      email: "Dev@Example.com"
    })
    await expect(read(true)).resolves.toBeUndefined()
  })
})

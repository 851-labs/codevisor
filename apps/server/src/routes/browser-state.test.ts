import { describe, expect, it } from "vitest"
import { jsonRequest, start } from "../test-support.js"

describe("native browser state API", () => {
  it("requires machine authentication and rejects website callers", async () => {
    const secured = await start({ requireBearerToken: true, allowLocalhostWithoutAuth: false })
    expect(
      (
        await jsonRequest(secured.server, "/v1/browser/state/cookies", {
          method: "POST",
          body: JSON.stringify({ mutations: [] })
        })
      ).status
    ).toBe(401)
    const { server } = await start()
    for (const headers of [
      { Origin: "https://example.test" },
      { "Sec-Fetch-Site": "same-origin" }
    ]) {
      expect(
        (
          await jsonRequest(server, "/v1/browser/state/cookies", {
            method: "POST",
            headers,
            body: JSON.stringify({ mutations: [] })
          })
        ).status
      ).toBe(403)
    }
    expect(
      (
        await jsonRequest(server, "/v1/browser/state/cookies", {
          method: "POST",
          body: JSON.stringify({ mutations: [] })
        })
      ).body
    ).toEqual({ revision: 0, entries: [] })
  })
  it("stores independent pane locations without exposing auth callbacks", async () => {
    const { server } = await start()
    const path = "/v1/browser/state/panes/fixture-pane"
    expect((await jsonRequest(server, path)).body).toEqual({ navigation: null })
    expect((await jsonRequest(server, "/v1/browser/state/unknown")).status).toBe(404)
    expect((await jsonRequest(server, path, { method: "POST" })).status).toBe(404)
    const navigation = { url: "http://localhost:3001/search?q=cat", title: "Search" }
    expect(
      (await jsonRequest(server, path, { method: "PUT", body: JSON.stringify(navigation) })).status
    ).toBe(200)
    expect((await jsonRequest(server, path)).body).toEqual({ navigation })
    await jsonRequest(server, path, {
      method: "PUT",
      body: JSON.stringify({ url: "https://example.test/callback?code=fixture", title: "Login" })
    })
    expect((await jsonRequest(server, path)).body).toEqual({ navigation })
    const response = await fetch(server.url + path)
    expect(response.headers.get("cache-control")).toBe("no-store")
    await response.text()
  })
})

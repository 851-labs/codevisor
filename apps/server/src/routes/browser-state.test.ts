import { createHash } from "node:crypto"
import { request } from "node:http"

import { describe, expect, it } from "vitest"

import { jsonRequest, start } from "../test-support.js"

describe("native browser state API", () => {
  it("requires machine authentication and rejects website callers", async () => {
    const secured = await start({
      requireBearerToken: true,
      allowLocalhostWithoutAuth: false
    })
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
    expect((await jsonRequest(server, path)).body).toEqual({
      navigation: null
    })
    expect((await jsonRequest(server, "/v1/browser/state/unknown")).status).toBe(404)
    expect((await jsonRequest(server, path, { method: "POST" })).status).toBe(404)
    const navigation = {
      url: "http://localhost:3001/search?q=cat",
      title: "Search"
    }
    expect(
      (
        await jsonRequest(server, path, {
          method: "PUT",
          body: JSON.stringify(navigation)
        })
      ).status
    ).toBe(200)
    expect((await jsonRequest(server, path)).body).toEqual({ navigation })
    await jsonRequest(server, path, {
      method: "PUT",
      body: JSON.stringify({
        url: "https://example.test/callback?code=fixture",
        title: "Login"
      })
    })
    expect((await jsonRequest(server, path)).body).toEqual({ navigation })
    const response = await fetch(server.url + path)
    expect(response.headers.get("cache-control")).toBe("no-store")
    await response.text()
  })
  it("shares favicons by content hash and rejects anything else", async () => {
    const { server } = await start()
    const png = pngHeader(64, 64)
    const upload = (data: Buffer, path = faviconPath(data)) =>
      jsonRequest(server, path, {
        method: "PUT",
        body: JSON.stringify({ data: data.toString("base64") })
      })
    expect((await jsonRequest(server, faviconPath(png))).body).toEqual({ favicon: null })
    expect((await upload(png)).status).toBe(200)
    expect((await jsonRequest(server, faviconPath(png))).body).toEqual({
      favicon: png.toString("base64")
    })
    expect((await upload(png, `/v1/browser/state/favicons/${"0".repeat(64)}`)).status).toBe(400)
    expect((await upload(Buffer.from("GIF89a"))).status).toBe(400)
    expect(
      (await jsonRequest(server, faviconPath(png), { method: "PUT", body: "{}" })).status
    ).toBe(400)
    expect((await upload(pngHeader(257, 16))).status).toBe(400)
    expect((await upload(pngHeader(16, 10_000))).status).toBe(400)
    expect((await upload(Buffer.concat([png, Buffer.alloc(131_072)]))).status).toBe(400)
    expect((await jsonRequest(server, "/v1/browser/state/favicons/not-a-hash")).status).toBe(404)
    expect((await jsonRequest(server, faviconPath(png), { method: "POST" })).status).toBe(404)
  })
  it("rejects an oversized favicon upload before the body ends", async () => {
    const { server } = await start()
    const status = await unfinishedUploadStatus(server.url + faviconPath(pngHeader(16, 16)))
    expect(status).toBe(413)
  })
})

const pngHeader = (width: number, height: number): Buffer => {
  const header = Buffer.alloc(33)
  Buffer.from("89504e470d0a1a0a0000000d49484452", "hex").copy(header)
  header.writeUInt32BE(width, 16)
  header.writeUInt32BE(height, 20)
  return header
}

const unfinishedUploadStatus = (url: string): Promise<number | undefined> =>
  new Promise((resolve, reject) => {
    const upload = request(url, { method: "PUT" }, (response) => {
      resolve(response.statusCode)
      response.resume()
      upload.destroy()
    })
    upload.once("error", reject)
    upload.write(`{"data":"${"A".repeat(200_000)}`)
  })

const faviconPath = (data: Buffer): string =>
  `/v1/browser/state/favicons/${createHash("sha256").update(data).digest("hex")}`

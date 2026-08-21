import sharp from "sharp"
import { describe, expect, it, vi } from "vitest"
import { fetchPluginIcon, MAX_PLUGIN_ICON_BYTES } from "./plugin-icon.js"
import { plugin } from "./test-support.js"

const safeSvg = `
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
    <defs><linearGradient id="paint"><stop stop-color="#7657e8"/></linearGradient></defs>
    <rect width="24" height="24" fill="url(#paint)"/>
    <use href="#shape"/><path id="shape" d="M2 2h20v20H2z"/>
  </svg>`

const response = (body: BodyInit | null, contentType?: string, headers = {}): Response =>
  new Response(body, {
    headers: { ...(contentType === undefined ? {} : { "content-type": contentType }), ...headers }
  })

const setup = (
  fetchImpl: typeof fetch,
  manifest: Parameters<typeof plugin>[0] = {
    iconPath: "/assets/plugin.svg",
    panes: [
      {
        iconPath: "/assets/pane.svg",
        path: "/panes/main/",
        title: "Main",
        type: "main"
      }
    ]
  }
) => {
  const noteSuccess = vi.fn()
  const markUnreachable = vi.fn()
  const signedContextHeaders = vi.fn(() => ({ "x-test-signature": "signed" }))
  return {
    markUnreachable,
    noteSuccess,
    options: {
      ensureRunning: async () => 4242,
      fetchImpl,
      markUnreachable,
      noteSuccess,
      plugin: plugin(manifest),
      signedContextHeaders,
      timeoutMs: 25
    },
    signedContextHeaders
  }
}

describe("fetchPluginIcon", () => {
  it("fetches plugin and pane SVG paths with signed context and normalizes them to PNG", async () => {
    const urls: string[] = []
    const fetchImpl = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      urls.push(String(input))
      expect(new Headers(init?.headers).get("accept")).toContain("image/svg+xml")
      expect(new Headers(init?.headers).get("x-test-signature")).toBe("signed")
      return response(safeSvg, "image/svg+xml; charset=utf-8")
    }) as unknown as typeof fetch
    const fixture = setup(fetchImpl)

    const pluginAsset = await fetchPluginIcon(fixture.options)
    const paneAsset = await fetchPluginIcon({ ...fixture.options, paneType: "main" })

    expect(urls).toEqual([
      "http://127.0.0.1:4242/assets/plugin.svg",
      "http://127.0.0.1:4242/assets/pane.svg"
    ])
    expect(pluginAsset.contentType).toBe("image/png")
    expect([...pluginAsset.data.slice(0, 8)]).toEqual([137, 80, 78, 71, 13, 10, 26, 10])
    expect(paneAsset.data.byteLength).toBeGreaterThan(0)
    expect(fixture.noteSuccess).toHaveBeenCalledTimes(2)
    expect(fixture.signedContextHeaders).toHaveBeenLastCalledWith({
      paneType: "main",
      pluginId: "owner.example",
      purpose: "icon"
    })
  })

  it("inherits the plugin icon for panes without an override", async () => {
    const fetchImpl = vi.fn(async () =>
      response(safeSvg, "image/svg+xml")
    ) as unknown as typeof fetch
    const fixture = setup(fetchImpl, {
      iconPath: "/assets/plugin.svg",
      panes: [{ path: "/panes/main/", title: "Main", type: "main" }]
    })
    await fetchPluginIcon({ ...fixture.options, paneType: "main" })
    expect(fetchImpl).toHaveBeenCalledWith(
      "http://127.0.0.1:4242/assets/plugin.svg",
      expect.any(Object)
    )
  })

  it("normalizes valid PNG and WebP assets", async () => {
    const source = { create: { background: "#7657e8", channels: 4 as const, height: 4, width: 4 } }
    const png = await sharp(source).png().toBuffer()
    const webp = await sharp(source).webp().toBuffer()
    for (const [body, contentType] of [
      [new Uint8Array(png), "image/png"],
      [new Uint8Array(webp), "image/webp"]
    ] as const) {
      const fixture = setup(
        vi.fn(async () => response(body, contentType)) as unknown as typeof fetch
      )
      const asset = await fetchPluginIcon(fixture.options)
      expect(asset.contentType).toBe("image/png")
      expect(asset.data.byteLength).toBeGreaterThan(0)
    }
  })

  it("rejects missing icon declarations and unknown pane types before fetching", async () => {
    const fetchImpl = vi.fn() as unknown as typeof fetch
    const noIcon = setup(fetchImpl, {
      panes: [{ path: "/panes/main/", title: "Main", type: "main" }]
    })
    await expect(fetchPluginIcon(noIcon.options)).rejects.toThrow(/has no icon/)
    await expect(fetchPluginIcon({ ...noIcon.options, paneType: "main" })).rejects.toThrow(
      /has no icon/
    )
    await expect(fetchPluginIcon({ ...noIcon.options, paneType: "missing" })).rejects.toThrow(
      /has no pane type/
    )
    expect(fetchImpl).not.toHaveBeenCalled()
  })

  it("rejects failed responses, missing or unsupported content types, and declared oversize", async () => {
    for (const [reply, message] of [
      [
        new Response("missing", { headers: { "content-type": "text/plain" }, status: 404 }),
        /HTTP 404/
      ],
      [response(new Uint8Array([1, 2, 3])), /no Content-Type/],
      [response("bytes", "image/jpeg"), /must be SVG, PNG, or WebP/],
      [
        response("bytes", "image/png", { "content-length": String(MAX_PLUGIN_ICON_BYTES + 1) }),
        /exceeds/
      ]
    ] as const) {
      const fixture = setup(vi.fn(async () => reply) as unknown as typeof fetch)
      await expect(fetchPluginIcon(fixture.options)).rejects.toThrow(message)
      expect(fixture.noteSuccess).toHaveBeenCalledOnce()
    }
  })

  it("stops reading a chunked response once it exceeds the byte cap", async () => {
    const body = new Uint8Array(MAX_PLUGIN_ICON_BYTES + 1)
    const fixture = setup(vi.fn(async () => response(body, "image/png")) as unknown as typeof fetch)
    await expect(fetchPluginIcon(fixture.options)).rejects.toThrow(/exceeds/)
  })

  it("handles an empty response body and malformed raster data", async () => {
    const emptyResponse = {
      body: null,
      headers: new Headers({ "content-type": "image/png" }),
      ok: true,
      status: 200
    } as Response
    for (const reply of [emptyResponse, response("not a png", "image/png")]) {
      const fixture = setup(vi.fn(async () => reply) as unknown as typeof fetch)
      await expect(fetchPluginIcon(fixture.options)).rejects.toThrow(/could not be decoded/)
    }
  })

  it("rejects invalid and active SVG documents", async () => {
    const cases: Array<[BodyInit, RegExp]> = [
      [new Uint8Array([0xff]), /valid UTF-8/],
      ["not svg", /not an SVG document/],
      ["<svg><script/></svg>", /active content/],
      ["<!DOCTYPE svg><svg></svg>", /document entity/],
      ['<svg><style>@import "https://example.com/icon.css";</style></svg>', /external stylesheet/],
      ['<svg><use href="https://example.com/icon.svg#x"/></svg>', /external reference/],
      ['<svg><rect fill="url(https://example.com/a.svg#x)"/></svg>', /external resource/]
    ]
    for (const [body, message] of cases) {
      const fixture = setup(
        vi.fn(async () => response(body, "image/svg+xml")) as unknown as typeof fetch
      )
      await expect(fetchPluginIcon(fixture.options)).rejects.toThrow(message)
    }
  })

  it("marks network failures and timeouts unreachable", async () => {
    for (const cause of [
      new Error("connection refused"),
      new DOMException("timed out", "TimeoutError")
    ]) {
      const fixture = setup(
        vi.fn(async () => {
          throw cause
        }) as unknown as typeof fetch
      )
      await expect(fetchPluginIcon(fixture.options)).rejects.toThrow(
        cause.name === "TimeoutError" ? /did not respond within/ : /request failed/
      )
      expect(fixture.markUnreachable).toHaveBeenCalledOnce()
      expect(fixture.noteSuccess).not.toHaveBeenCalled()
    }
  })
})

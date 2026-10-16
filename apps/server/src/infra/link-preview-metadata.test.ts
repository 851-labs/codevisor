import { describe, expect, it } from "vitest"

import { decodeEntities, parseLinkPreviewMetadata } from "./link-preview-metadata.js"

describe("link preview metadata", () => {
  it("prefers Open Graph tags, then Twitter tags, then the document title", () => {
    const html = `<head>
      <title>Plain title</title>
      <meta name="twitter:title" content="Twitter title">
      <meta content="Graph title" property="og:title">
      <meta property="og:title" content="Second graph title">
      <meta name="description" content="  Spread
        over lines  ">
      <meta name="application-name" content="App">
      <meta property="og:image" content="/social.png">
      <meta name="viewport">
      <meta content="orphan">
    </head>`
    expect(parseLinkPreviewMetadata(html, "https://site.test/docs/page")).toEqual({
      title: "Graph title",
      description: "Spread over lines",
      siteName: "App",
      imageUrl: "https://site.test/social.png"
    })
    expect(
      parseLinkPreviewMetadata(
        `<meta name="twitter:title" content="Twitter title"><meta name="twitter:image:src" content="https://cdn.test/a.png">`,
        "https://site.test/"
      )
    ).toEqual({ title: "Twitter title", imageUrl: "https://cdn.test/a.png" })
    expect(
      parseLinkPreviewMetadata("<title data-x>Only &amp; title</title>", "https://site.test/")
    ).toEqual({ title: "Only & title" })
    expect(parseLinkPreviewMetadata("<title>  </title>", "https://site.test/")).toEqual({})
  })

  it("skips images that aren't web URLs and keeps looking", () => {
    const html = `
      <meta property="og:image:secure_url" content="data:image/png;base64,AAAA">
      <meta property="og:image" content="http://[broken">
      <meta property="og:image:url" content="javascript:alert(1)">
      <meta name="twitter:image" content="https://cdn.test/card.png?a=1&amp;b=2">`
    expect(parseLinkPreviewMetadata(html, "https://site.test/").imageUrl).toBe(
      "https://cdn.test/card.png?a=1&b=2"
    )
  })

  it("finds the meta refresh target", () => {
    expect(
      parseLinkPreviewMetadata(
        `<meta http-equiv="Refresh" content="0; url='next/page'">`,
        "https://site.test/docs/"
      )
    ).toEqual({ refreshUrl: "https://site.test/docs/next/page" })
    expect(
      parseLinkPreviewMetadata(`<meta http-equiv="refresh" content="5">`, "https://site.test/")
    ).toEqual({})
  })

  it("decodes named, numeric and twice-escaped entities", () => {
    expect(decodeEntities("&lt;a&gt; &quot;b&quot; &apos;c&#39; d&nbsp;e")).toBe(
      "<a> \"b\" 'c' d e"
    )
    expect(decodeEntities("&#x1F600; &#X41; &#0; &#x110000; &copy;")).toBe(
      "😀 A &#0; &#x110000; &copy;"
    )
    expect(
      parseLinkPreviewMetadata(
        `<meta property="og:title" content="It&amp;#39;s">`,
        "https://a.test/"
      ).title
    ).toBe("It's")
  })
})

import { homedir } from "node:os"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { localArtifactPath, markdownFileReferences } from "./markdown-artifacts.js"

describe("Markdown artifact paths", () => {
  it("resolves local URLs and home paths without guessing a relative working directory", () => {
    expect(localArtifactPath("file:///tmp/screen%20shot.png", undefined)).toBe(
      "/tmp/screen shot.png"
    )
    expect(localArtifactPath("~/Pictures/shot.png", undefined)).toBe(
      resolve(homedir(), "Pictures/shot.png")
    )
    expect(localArtifactPath("/tmp/shot.png", undefined)).toBe("/tmp/shot.png")
    expect(localArtifactPath("./shot.png", undefined)).toBeUndefined()
    expect(localArtifactPath("./shot%broken.png", "/tmp")).toBeUndefined()
    expect(localArtifactPath("file://remote-host/shot.png", "/tmp")).toBeUndefined()
  })

  it.each([
    "``literal ` ![Hidden](./hidden.png)`` ![Visible](./visible.png)",
    "`literal ``![Hidden](./hidden.png)`` after` ![Visible](./visible.png)",
    "`unclosed ![Visible](./visible.png)",
    "`unclosed\n~~~\n` ![Hidden](./hidden.png)\n~~~\n![Visible](./visible.png)",
    "```invalid`info\n![Visible](./visible.png)",
    "\\`![Visible](./visible.png)"
  ])("keeps code spans and unmatched backticks literal: %s", (markdown) => {
    const references = markdownFileReferences(markdown)
    expect(references.map((reference) => reference.target)).toEqual(["./visible.png"])
    for (const reference of references)
      expect(markdown.slice(reference.start, reference.end)).toBe(reference.target)
  })
})

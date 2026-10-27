import { describe, expect, it } from "vitest"

import {
  manifestFile,
  pluginSkill,
  supportingFiles,
  verifiedSkillFile
} from "./mcp-plugin-skill-manifest.js"
import { fileDigest } from "./mcp-plugin-test-support.js"

const document = "---\nname: deploy\n---\nShip it.\n"

const entry = (text: string, extra: ReadonlyArray<Record<string, unknown>> = []) => ({
  uri: "skill://deploy/SKILL.md",
  frontmatter: { name: "deploy" },
  resources: [
    {
      uri: "skill://deploy/SKILL.md",
      digest: fileDigest(Buffer.from(text)),
      size: Buffer.byteLength(text)
    },
    ...extra
  ]
})

describe("plugin skill manifests", () => {
  it("names files outside the skill folder by their full URI", () => {
    const skill = pluginSkill(
      entry(document, [{ uri: "https://cdn.example/shared.md", digest: "sha256:1", size: 1 }])
    )!

    expect(supportingFiles(skill)).toEqual(["https://cdn.example/shared.md"])
    expect(manifestFile(skill, "https://cdn.example/shared.md")?.uri).toBe(
      "https://cdn.example/shared.md"
    )
  })

  it("rejects reads that don't return the requested file", () => {
    const skill = pluginSkill(entry(document))!
    const file = manifestFile(skill, "SKILL.md")!

    expect(
      verifiedSkillFile(skill, file, {
        contents: [{ uri: "skill://other/SKILL.md", text: document }]
      })
    ).toBeUndefined()
  })

  it("rejects a SKILL.md whose frontmatter can't be parsed", () => {
    const broken = "---\nname: [deploy\n---\nShip it.\n"
    const skill = pluginSkill(entry(broken))!
    const file = manifestFile(skill, "SKILL.md")!

    expect(verifiedSkillFile(skill, file, { contents: [{ uri: file.uri, text: broken }] })).toBe(
      undefined
    )
  })
})

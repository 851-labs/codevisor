import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "bun:test"
import { backfillReleaseNotes } from "./backfill-release-notes.mjs"
import {
  cleanCommitBody,
  collectCommits,
  findPreviousPublishedTag,
  generateReleaseNotes,
  parseHighlightsResponse,
  renderReleaseNotes,
  requestHighlights,
  shouldRefreshReleaseBody
} from "./generate-release-notes.mjs"

const runGit = (cwd: string, ...args: string[]) =>
  execFileSync("git", args, { cwd, encoding: "utf8" }).trim()

const makeRepository = () => {
  const cwd = mkdtempSync(join(tmpdir(), "codevisor-release-notes-"))
  runGit(cwd, "init", "--quiet")
  runGit(cwd, "config", "user.name", "Codevisor Test")
  runGit(cwd, "config", "user.email", "test@codevisor.dev")

  const commit = (subject: string, body?: string) => {
    const path = join(cwd, `${subject.replace(/\W+/g, "-")}.txt`)
    writeFileSync(path, subject)
    runGit(cwd, "add", ".")
    const args = ["commit", "--quiet", "-m", subject]
    if (body !== undefined) {
      args.push("-m", body)
    }
    runGit(cwd, ...args)
  }

  commit("Initial feature")
  runGit(cwd, "tag", "v0.1.0")
  commit("Change on failed tag")
  runGit(cwd, "tag", "v0.1.1")
  commit(
    "Fix visible behavior",
    "Explains the user-facing fix.\n\nCo-Authored-By: Bot <bot@example.com>"
  )
  runGit(cwd, "tag", "v0.1.2")
  commit("Future change")
  runGit(cwd, "tag", "v0.1.3")

  return cwd
}

describe("release-note commit ranges", () => {
  it("includes repository history in the first release", () => {
    const cwd = makeRepository()
    expect(collectCommits({ target: "v0.1.0", cwd }).map((commit) => commit.subject)).toEqual([
      "Initial feature"
    ])
  })

  it("uses published boundaries and includes commits from a failed intermediate tag", () => {
    const cwd = makeRepository()
    const commits = collectCommits({ target: "v0.1.2", previousTag: "v0.1.0", cwd })
    expect(commits.map((commit) => commit.subject)).toEqual([
      "Change on failed tag",
      "Fix visible behavior"
    ])
    expect(commits[1]?.body).toBe("Explains the user-facing fix.")
  })

  it("chooses the newest published ancestor instead of a later release", () => {
    const cwd = makeRepository()
    const releases = [
      { tag_name: "v0.1.0", published_at: "2026-01-01T00:00:00Z" },
      { tag_name: "v0.1.2", published_at: "2026-01-02T00:00:00Z" },
      { tag_name: "v0.1.3", published_at: "2026-01-03T00:00:00Z" }
    ]
    expect(findPreviousPublishedTag({ tag: "v0.1.2", target: "v0.1.2", releases, cwd })).toBe(
      "v0.1.0"
    )
  })
})

describe("release-note summaries", () => {
  it("cleans authorship trailers from model input", () => {
    expect(
      cleanCommitBody(
        "Useful explanation.\n\nCo-authored-by: Person <person@example.com>\nSigned-off-by: Person"
      )
    ).toBe("Useful explanation.")
  })

  it("parses fenced model JSON and normalizes bullets", () => {
    expect(
      parseHighlightsResponse(
        '```json\n{"highlights":["- Adds useful behavior","Fixes a bug"]}\n```'
      )
    ).toEqual(["Adds useful behavior", "Fixes a bug"])
  })

  it("retries a transient model error", async () => {
    let attempts = 0
    const highlights = await requestHighlights(
      [{ subject: "Add feature", body: "", paths: ["apps/web/feature.ts"] }],
      {
        token: "test-token",
        sleepImplementation: async () => {},
        fetchImplementation: async () => {
          attempts += 1
          if (attempts === 1) {
            return new Response("temporarily unavailable", { status: 503 })
          }
          return Response.json({
            choices: [{ message: { content: '{"highlights":["Adds a feature"]}' } }]
          })
        }
      }
    )
    expect(highlights).toEqual(["Adds a feature"])
    expect(attempts).toBe(2)
  })
})

describe("release-note rendering", () => {
  const commit = {
    sha: "0123456789abcdef",
    shortSha: "0123456",
    author: "A *Maintainer*",
    subject: "Add [linked] behavior",
    body: "",
    paths: []
  }

  it("renders model highlights, every commit, and current-repository links", () => {
    const notes = renderReleaseNotes({
      tag: "v0.2.0",
      previousTag: "v0.1.0",
      repository: "851-labs/codevisor",
      commits: [commit],
      highlights: ["Adds linked behavior"]
    })
    expect(notes).toContain("codevisor-release-notes:v1 summary=model")
    expect(notes).toContain("## All changes")
    expect(notes).toContain("Add \\[linked\\] behavior")
    expect(notes).toContain("https://github.com/851-labs/codevisor/commit/0123456789abcdef")
    expect(notes).toContain("compare/v0.1.0...v0.2.0")
  })

  it("marks fallback bodies for a later retry", async () => {
    const cwd = makeRepository()
    const output = "notes.md"
    await generateReleaseNotes({
      tag: "v0.1.2",
      target: "v0.1.2",
      previousTag: "v0.1.0",
      repository: "851-labs/codevisor",
      output,
      cwd,
      token: ""
    })
    const notes = readFileSync(join(cwd, output), "utf8")
    expect(notes).toContain("codevisor-release-notes:v1 summary=fallback")
    expect(shouldRefreshReleaseBody(notes)).toBe(true)
    expect(shouldRefreshReleaseBody(notes.replace("summary=fallback", "summary=model"))).toBe(false)
  })
})

describe("release-note backfill", () => {
  it("resumes from a selected tag and keeps published release boundaries", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "codevisor-release-backfill-"))
    const generated: Array<{ tag: string; previousTag?: string }> = []
    const edited: string[] = []
    const releases = [
      {
        tag_name: "v0.1.0",
        published_at: "2026-01-01T00:00:00Z",
        body: "legacy"
      },
      {
        tag_name: "v0.1.2",
        published_at: "2026-01-02T00:00:00Z",
        body: "<!-- codevisor-release-notes:v1 summary=model -->"
      },
      {
        tag_name: "v0.1.3",
        published_at: "2026-01-03T00:00:00Z",
        body: "legacy"
      }
    ]

    const result = await backfillReleaseNotes({
      cwd,
      apply: true,
      startTag: "v0.1.2",
      listReleases: () => releases,
      generate: async (options: { tag: string; previousTag?: string; output: string }) => {
        generated.push({ tag: options.tag, previousTag: options.previousTag })
        writeFileSync(options.output, "notes")
        return { outputPath: options.output, commits: [{ subject: "Change" }] }
      },
      edit: ({ tag }: { tag: string }) => edited.push(tag)
    })

    expect(generated).toEqual([{ tag: "v0.1.3", previousTag: "v0.1.2" }])
    expect(edited).toEqual(["v0.1.3"])
    expect(result).toMatchObject({ releases: 2, availableReleases: 3, updated: 1, skipped: 1 })
  })
})

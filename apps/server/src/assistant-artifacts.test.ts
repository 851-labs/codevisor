import {
  makeAttachmentStore,
  makeDatabase,
  type AttachmentStore,
  type CodevisorDatabaseService
} from "@codevisor/db"
import { Effect } from "effect"
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  truncateSync,
  utimesSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { afterEach, describe, expect, it } from "vitest"
import {
  ASSISTANT_ARTIFACT_ORIGIN,
  assistantArtifactDirectory,
  finalizeAssistantArtifacts
} from "./assistant-artifacts.js"

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []
const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const fixture = async () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-assistant-artifacts-"))
  directories.push(directory)
  const cwd = join(directory, "project")
  mkdirSync(cwd)
  const db = await run(
    makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "local" })
  )
  databases.push(db)
  return { cwd, db, attachments: makeAttachmentStore(directory) }
}

afterEach(async () => {
  for (const db of databases.splice(0)) await run(db.close)
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

describe("assistant artifact finalization", () => {
  it("promotes normal Markdown links and also discovers unlinked managed outputs", async () => {
    const services = await fixture()
    writeFileSync(join(services.cwd, "recording.mov"), "video bytes")
    writeFileSync(join(services.cwd, "screen shot.mov"), "spaced video bytes")
    writeFileSync(join(services.cwd, "screenshot.png"), "image bytes")
    writeFileSync(join(services.cwd, "bundle.tar"), "archive bytes")
    mkdirSync(join(services.cwd, "src"))
    writeFileSync(join(services.cwd, "src", "main.ts"), "export {}")
    const managed = assistantArtifactDirectory(services.cwd, "session-1")
    mkdirSync(managed, { recursive: true })
    mkdirSync(join(managed, "nested"))
    writeFileSync(join(managed, "nested", "report.pdf"), "%PDF result")
    writeFileSync(join(managed, "unlinked.pdf"), "%PDF unlinked")
    writeFileSync(join(managed, "old.pdf"), "%PDF old")
    utimesSync(join(managed, "old.pdf"), new Date(0), new Date(0))
    symlinkSync(join(services.cwd, "missing-target"), join(managed, "pending-link"))

    const screenshotPath = join(services.cwd, "screenshot.png")
    const bundleUrl = pathToFileURL(join(services.cwd, "bundle.tar")).href

    const result = await finalizeAssistantArtifacts(services, {
      cwd: services.cwd,
      sessionId: "session-1",
      markdown: [
        "Fixed.",
        "[Screen recording](recording.mov)",
        "[Duplicate recording](recording.mov)",
        "[Spaced recording](screen%20shot.mov)",
        `![Screenshot](${screenshotPath})`,
        `[Archive](${bundleUrl})`,
        "[Report](.codevisor/artifacts/session-1/nested/report.pdf)",
        "[source](src/main.ts)",
        "[section](#details)",
        "[remote](https://example.com/file.pdf)",
        `[attached](${ASSISTANT_ARTIFACT_ORIGIN}existing)`,
        "[entity](a&amp;b.png)"
      ].join(" "),
      startedAt: new Date(Date.now() - 1_000).toISOString()
    })

    expect(result.changed).toBe(true)
    expect(result.markdown).toContain(`[Screen recording](${ASSISTANT_ARTIFACT_ORIGIN}`)
    expect(result.markdown).toContain("[source](src/main.ts)")
    expect(result.attachments.map((attachment) => attachment.name).sort()).toEqual([
      "bundle.tar",
      "recording.mov",
      "report.pdf",
      "screen shot.mov",
      "screenshot.png",
      "unlinked.pdf"
    ])
    expect(
      result.attachments.find((attachment) => attachment.name === "recording.mov")?.mimeType
    ).toBe("video/quicktime")
    expect(
      result.attachments.find((attachment) => attachment.name === "screenshot.png")
    ).toMatchObject({ kind: "image", mimeType: "image/png" })
    expect(
      result.attachments.find((attachment) => attachment.name === "bundle.tar")?.mimeType
    ).toBe("application/octet-stream")
  })

  it("is idempotent and refuses a symlink that escapes the workspace", async () => {
    const services = await fixture()
    const managed = assistantArtifactDirectory(services.cwd, "session-2")
    mkdirSync(managed, { recursive: true })
    writeFileSync(join(managed, "capture.mp4"), "video bytes")
    const outside = join(services.cwd, "..", "secret.pdf")
    writeFileSync(outside, "secret")
    symlinkSync(outside, join(services.cwd, "escaped.pdf"))

    const first = await finalizeAssistantArtifacts(services, {
      cwd: services.cwd,
      sessionId: "session-2",
      markdown: "[unsafe](escaped.pdf)",
      startedAt: new Date(Date.now() - 1_000).toISOString()
    })
    expect(first.markdown).toBe("[unsafe](escaped.pdf)")
    expect(first.attachments).toHaveLength(1)

    writeFileSync(join(services.cwd, "capture-copy.mp4"), "video bytes")
    const second = await finalizeAssistantArtifacts(services, {
      cwd: services.cwd,
      sessionId: "session-2",
      markdown: "[same bytes](capture-copy.mp4)",
      existingAttachments: first.attachments,
      startedAt: new Date(Date.now() - 1_000).toISOString()
    })
    expect(second.changed).toBe(true)
    expect(second.attachments).toEqual(first.attachments)

    const third = await finalizeAssistantArtifacts(services, {
      cwd: services.cwd,
      sessionId: "session-2",
      markdown: second.markdown,
      existingAttachments: second.attachments,
      startedAt: new Date(Date.now() - 1_000).toISOString()
    })
    expect(third.changed).toBe(false)
    expect(third.attachments).toEqual(first.attachments)
  })

  it("ignores unsafe, missing, oversized, and non-file Markdown targets", async () => {
    const services = await fixture()
    mkdirSync(join(services.cwd, "folder"))
    writeFileSync(join(services.cwd, "huge.mp4"), "")
    truncateSync(join(services.cwd, "huge.mp4"), 256 * 1024 * 1024 + 1)
    const outside = join(services.cwd, "..", "outside.mov")
    writeFileSync(outside, "outside")
    symlinkSync(outside, join(services.cwd, "escaped.mov"))
    const markdown = [
      "[folder](folder)",
      "[huge](huge.mp4)",
      "[missing](missing.png)",
      "[escaped](escaped.mov)",
      "[bad escape](bad%ZZ.png)",
      "[bad file URL](file://%)",
      "[remote](mailto:test@example.com)",
      "[section](#result)",
      `[attached](${ASSISTANT_ARTIFACT_ORIGIN}existing)`
    ].join(" ")

    const result = await finalizeAssistantArtifacts(services, {
      cwd: services.cwd,
      sessionId: "session-safety",
      markdown
    })

    expect(result).toEqual({ attachments: [], changed: false, markdown })
  })

  it("caps automatic discovery and respects a pre-filled attachment limit", async () => {
    const services = await fixture()
    const managed = assistantArtifactDirectory(services.cwd, "session-limit")
    mkdirSync(managed, { recursive: true })
    for (let index = 0; index < 13; index += 1) {
      writeFileSync(
        join(managed, `artifact-${String(index).padStart(2, "0")}.pdf`),
        `file-${index}`
      )
    }
    const placeholder = {
      fileId: "missing-file",
      kind: "file" as const,
      mimeType: "application/pdf",
      name: "existing.pdf",
      sizeBytes: 1
    }

    const discovered = await finalizeAssistantArtifacts(services, {
      cwd: services.cwd,
      sessionId: "session-limit",
      markdown: "done",
      existingAttachments: [placeholder],
      startedAt: "invalid"
    })
    expect(discovered.attachments).toHaveLength(12)

    const full = Array.from({ length: 12 }, (_, index) => ({
      ...placeholder,
      fileId: `missing-${index}`
    }))
    const limited = await finalizeAssistantArtifacts(services, {
      cwd: services.cwd,
      sessionId: "session-limit",
      markdown: "[extra](artifact.pdf)",
      existingAttachments: full
    })
    expect(limited).toEqual({
      attachments: full,
      changed: false,
      markdown: "[extra](artifact.pdf)"
    })
  })

  it("leaves files untouched when promotion loses a filesystem race", async () => {
    const services = await fixture()
    writeFileSync(join(services.cwd, "linked.mov"), "linked")
    const managed = assistantArtifactDirectory(services.cwd, "session-race")
    mkdirSync(managed, { recursive: true })
    writeFileSync(join(managed, "unlinked.mov"), "unlinked")
    const failingAttachments: AttachmentStore = {
      ...services.attachments,
      putStream: async (source) => {
        for await (const _chunk of source) {
          // Drain the stream so the simulated promotion failure cannot leave a
          // late filesystem event behind after the fixture is removed.
        }
        throw new Error("file disappeared")
      }
    }

    const result = await finalizeAssistantArtifacts(
      { ...services, attachments: failingAttachments },
      {
        cwd: services.cwd,
        sessionId: "session-race",
        markdown: "[recording](linked.mov)",
        startedAt: new Date(Date.now() - 1_000).toISOString()
      }
    )

    expect(result).toEqual({
      attachments: [],
      changed: false,
      markdown: "[recording](linked.mov)"
    })
  })
})

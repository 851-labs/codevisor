import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { test } from "node:test"
import { verifyAppcast } from "./verify-appcast.mjs"

const repositoryRoot = resolve(import.meta.dirname, "../..")
const runNode = (script, args, options = {}) =>
  execFileSync(process.execPath, [join(repositoryRoot, script), ...args], {
    encoding: "utf8",
    ...options
  })

test("stable appcast promotion replaces the matching Alpha item", () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-appcast-"))
  const input = join(directory, "old.xml")
  const output = join(directory, "new.xml")
  writeFileSync(
    input,
    `<?xml version="1.0"?>
<rss><channel>
  <item>
    <sparkle:version>42</sparkle:version>
    <sparkle:channel>alpha</sparkle:channel>
  </item>
  <item>
    <sparkle:version>41</sparkle:version>
  </item>
</channel></rss>`
  )

  runNode("scripts/release/update-appcast.mjs", [
    "--input",
    input,
    "--output",
    output,
    "--channel",
    "stable",
    "--version",
    "1.1.0",
    "--build",
    "42",
    "--url",
    "https://updates.codevisor.dev/updates/v1.1.0/Codevisor.zip",
    "--signature",
    "signature",
    "--length",
    "123",
    "--release-notes-url",
    "https://github.com/851-labs/codevisor/releases/tag/v1.1.0",
    "--publication-date",
    "Thu, 23 Jul 2026 12:00:00 GMT"
  ])

  const feed = readFileSync(output, "utf8")
  assert.equal(feed.match(/<sparkle:version>42<\/sparkle:version>/g)?.length, 1)
  assert.match(feed, /<sparkle:version>41<\/sparkle:version>/)
  assert.doesNotMatch(feed, /<sparkle:channel>alpha<\/sparkle:channel>/)
  assert.match(feed, /<sparkle:shortVersionString>1\.1\.0<\/sparkle:shortVersionString>/)
})

test("release-note retries ignore tags at the release commit", () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-release-notes-"))
  const git = (...args) => execFileSync("git", args, { cwd: directory, encoding: "utf8" }).trim()
  git("init", "--quiet")
  git("config", "user.name", "Codevisor Test")
  git("config", "user.email", "test@codevisor.dev")
  writeFileSync(join(directory, "fixture.txt"), "base\n")
  git("add", ".")
  git("commit", "--quiet", "-m", "chore: Base release")
  git("tag", "v1.0.0")
  writeFileSync(join(directory, "fixture.txt"), "base\nfeature\n")
  git("commit", "--quiet", "-am", "feat: Add the updater")
  writeFileSync(join(directory, "fixture.txt"), "base\nfeature\nfix\n")
  git("commit", "--quiet", "-am", "fix: Repair update retries")
  git("tag", "v1.1.0-alpha.42")
  git("tag", "v1.1.0")

  const output = join(directory, "notes.md")
  runNode(
    "scripts/release/generate-release-notes.mjs",
    ["--channel", "stable", "--version", "1.1.0", "--commit", "HEAD", "--output", output],
    { cwd: directory }
  )

  const notes = readFileSync(output, "utf8")
  assert.match(notes, /Add the updater/)
  assert.match(notes, /Repair update retries/)
  assert.equal(notes.match(/https:\/\/github\.com\/851-labs\/codevisor\/commit\//g)?.length, 2)
  assert.doesNotMatch(notes, /Base release/)
})

test("appcast verification requires the matching channel and signed enclosure", () => {
  const feed = `<?xml version="1.0"?>
<rss><channel>
  <item>
    <sparkle:version>42</sparkle:version>
    <sparkle:channel>alpha</sparkle:channel>
    <enclosure url="https://updates.codevisor.dev/Codevisor.zip" length="123" sparkle:edSignature="signature" />
  </item>
</channel></rss>`

  assert.doesNotThrow(() => verifyAppcast(feed, "42", "alpha"))
  assert.throws(() => verifyAppcast(feed, "42", "stable"), /still has the alpha channel/)
  assert.throws(() => verifyAppcast(feed, "41", "alpha"), /exactly one appcast item/)
  assert.throws(
    () => verifyAppcast(feed.replace(' sparkle:edSignature="signature"', ""), "42", "alpha"),
    /no EdDSA signature/
  )
})

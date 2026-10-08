import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { test } from "node:test"

import { signSparkleUpdate } from "./sign-sparkle-update.mjs"
import { verifyAppcast } from "./verify-appcast.mjs"

const repositoryRoot = resolve(import.meta.dirname, "../..")
const runNode = (script, args, options = {}) =>
  execFileSync(process.execPath, [join(repositoryRoot, script), ...args], {
    encoding: "utf8",
    ...options
  })

test("stable appcast promotion replaces the matching Alpha item", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-appcast-"))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
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
    "https://updates.codevisor.dev/updates/v1.1.0/release-notes-v1.1.0.md",
    "--release-page-url",
    "https://github.com/851-labs/codevisor/releases/tag/v1.1.0",
    "--full-release-notes-url",
    "https://github.com/851-labs/codevisor/releases",
    "--publication-date",
    "Thu, 23 Jul 2026 12:00:00 GMT"
  ])

  const feed = readFileSync(output, "utf8")
  assert.equal(feed.match(/<sparkle:version>42<\/sparkle:version>/g)?.length, 1)
  assert.match(feed, /<sparkle:version>41<\/sparkle:version>/)
  assert.doesNotMatch(feed, /<sparkle:channel>alpha<\/sparkle:channel>/)
  assert.match(feed, /<sparkle:shortVersionString>1\.1\.0<\/sparkle:shortVersionString>/)
  assert.match(
    feed,
    /<sparkle:releaseNotesLink>https:\/\/updates\.codevisor\.dev\/updates\/v1\.1\.0\/release-notes-v1\.1\.0\.md<\/sparkle:releaseNotesLink>/
  )
  assert.match(
    feed,
    /<link>https:\/\/github\.com\/851-labs\/codevisor\/releases\/tag\/v1\.1\.0<\/link>/
  )
  assert.match(
    feed,
    /<sparkle:fullReleaseNotesLink>https:\/\/github\.com\/851-labs\/codevisor\/releases<\/sparkle:fullReleaseNotesLink>/
  )
})

test("release-note retries ignore tags at the release commit", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-release-notes-"))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
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
  const featureCommit = git("rev-parse", "HEAD")
  git("tag", "v1.1.0-alpha.41", featureCommit)
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

  runNode(
    "scripts/release/generate-release-notes.mjs",
    ["--channel", "alpha", "--version", "1.1.0-alpha.42", "--commit", "HEAD", "--output", output],
    { cwd: directory }
  )
  const alphaNotes = readFileSync(output, "utf8")
  assert.match(alphaNotes, /Add the updater/)
  assert.match(alphaNotes, /Repair update retries/)
  assert.equal(alphaNotes.match(/https:\/\/github\.com\/851-labs\/codevisor\/commit\//g)?.length, 2)
  assert.doesNotMatch(alphaNotes, /Base release/)
})

const verificationFeed = `<?xml version="1.0"?>
<rss><channel>
  <item>
    <sparkle:version>42</sparkle:version>
    <sparkle:channel>alpha</sparkle:channel>
    <link>https://github.com/851-labs/codevisor/releases/tag/v1.1.0-alpha.42</link>
    <sparkle:releaseNotesLink>https://updates.codevisor.dev/updates/v1.1.0-alpha.42/release-notes-v1.1.0-alpha.42.md</sparkle:releaseNotesLink>
    <sparkle:fullReleaseNotesLink>https://github.com/851-labs/codevisor/releases</sparkle:fullReleaseNotesLink>
    <enclosure url="https://updates.codevisor.dev/Codevisor.zip" length="123" sparkle:edSignature="signature" />
  </item>
</channel></rss>`

test("appcast verification requires native release notes metadata and a signed enclosure", () => {
  const feed = verificationFeed

  assert.doesNotThrow(() => verifyAppcast(feed, "42", "alpha"))
  assert.throws(() => verifyAppcast(feed, "42", "stable"), /still has the alpha channel/)
  assert.throws(() => verifyAppcast(feed, "41", "alpha"), /exactly one appcast item/)
  assert.throws(
    () => verifyAppcast(feed.replace(' sparkle:edSignature="signature"', ""), "42", "alpha"),
    /no EdDSA signature/
  )
  assert.throws(
    () =>
      verifyAppcast(
        feed.replace(
          "release-notes-v1.1.0-alpha.42.md",
          "https-release-notes-v1.1.0-alpha.42.html"
        ),
        "42",
        "alpha"
      ),
    /no HTTPS Markdown release notes URL/
  )
  assert.throws(
    () =>
      verifyAppcast(
        feed.replace(
          "    <link>https://github.com/851-labs/codevisor/releases/tag/v1.1.0-alpha.42</link>\n",
          ""
        ),
        "42",
        "alpha"
      ),
    /no HTTPS release page URL/
  )
  assert.throws(
    () =>
      verifyAppcast(
        feed.replace(
          "    <sparkle:fullReleaseNotesLink>https://github.com/851-labs/codevisor/releases</sparkle:fullReleaseNotesLink>\n",
          ""
        ),
        "42",
        "alpha"
      ),
    /no HTTPS full release notes URL/
  )
})

test("appcast verification rejects an invalid build before channel or contents", () => {
  assert.throws(() => verifyAppcast(null, "42x", "beta"), {
    message: "build must be an integer"
  })
})

test("appcast verification rejects an unsupported channel before contents", () => {
  assert.throws(() => verifyAppcast(null, "42", "beta"), {
    message: "expected channel must be alpha or stable"
  })
})

test("appcast verification rejects duplicate builds before item metadata", () => {
  const feed = "<item><sparkle:version>42</sparkle:version></item>".repeat(2)
  assert.throws(() => verifyAppcast(feed, "42", "alpha"), {
    message: "expected exactly one appcast item for build 42"
  })
})

test("appcast verification requires the Alpha channel before release metadata", () => {
  assert.throws(
    () => verifyAppcast("<item><sparkle:version>42</sparkle:version></item>", "42", "alpha"),
    { message: "build 42 is not on the Alpha channel" }
  )
})

test("appcast verification requires an enclosure", () => {
  const feed = verificationFeed.replace(
    '    <enclosure url="https://updates.codevisor.dev/Codevisor.zip" length="123" sparkle:edSignature="signature" />',
    ""
  )
  assert.throws(() => verifyAppcast(feed, "42", "alpha"), {
    message: "build 42 has no enclosure"
  })
})

test("appcast verification requires HTTPS enclosure URLs before length and signature", () => {
  const feed = verificationFeed.replace(
    '<enclosure url="https://updates.codevisor.dev/Codevisor.zip" length="123" sparkle:edSignature="signature" />',
    '<enclosure url="http://updates.codevisor.dev/Codevisor.zip" length="0" />'
  )
  assert.throws(() => verifyAppcast(feed, "42", "alpha"), {
    message: "build 42 has no HTTPS enclosure URL"
  })
})

test("appcast verification requires positive enclosure length before signature", () => {
  const feed = verificationFeed.replace(
    'length="123" sparkle:edSignature="signature"',
    'length="0"'
  )
  assert.throws(() => verifyAppcast(feed, "42", "alpha"), {
    message: "build 42 has no positive enclosure length"
  })
})

test("Sparkle signing matches the RFC 8032 Ed25519 test vector", () => {
  const seed = Buffer.from(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "hex"
  ).toString("base64")
  const publicKey = Buffer.from(
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    "hex"
  ).toString("base64")

  assert.equal(
    Buffer.from(signSparkleUpdate(Buffer.alloc(0), seed, publicKey), "base64").toString("hex"),
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" +
      "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
  )
  assert.throws(
    () => signSparkleUpdate(Buffer.alloc(0), seed, Buffer.alloc(32).toString("base64")),
    /does not match/
  )
})

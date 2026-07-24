#!/usr/bin/env node
import { execFileSync } from "node:child_process"
import { writeFileSync } from "node:fs"

const option = (name) => {
  const index = process.argv.indexOf(`--${name}`)
  return index < 0 ? undefined : process.argv[index + 1]
}

const channel = option("channel")
const version = option("version")
const commit = option("commit") ?? "HEAD"
const output = option("output")
const repository = process.env.GITHUB_REPOSITORY ?? "851-labs/codevisor"

if (!["alpha", "stable"].includes(channel) || !version || !output) {
  throw new Error(
    "usage: generate-release-notes.mjs --channel <alpha|stable> --version <version> --commit <sha> --output <path>"
  )
}

const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim()
const commitSHA = git("rev-parse", commit)
const tags = git("tag", "--merged", commit, "--sort=-version:refname")
  .split("\n")
  .filter(Boolean)
  // A publication retry runs after its tag may already have been pushed.
  // Never use a tag at the release commit as its own changelog baseline.
  .filter((tag) => git("rev-list", "-n", "1", tag) !== commitSHA)
const stablePattern = /^v\d+\.\d+\.\d+$/
// Every channel presents a complete release changelog from the last Stable
// version. An earlier Alpha may have failed publication or may only represent
// an intermediate snapshot; neither is a safe user-facing baseline.
const baseTag = tags.find(stablePattern.test.bind(stablePattern))
const range = baseTag ? `${baseTag}..${commit}` : commit
const records = git("log", "--no-merges", "--format=%H%x09%s", range)
  .split("\n")
  .filter(Boolean)
  .map((line) => {
    const [sha, ...subjectParts] = line.split("\t")
    return { sha, subject: subjectParts.join("\t").trim() }
  })
if (records.length === 0) {
  throw new Error(`No release-note commits found in ${range}`)
}

const groups = { Added: [], Fixed: [], Changed: [] }
for (const record of records) {
  const normalized = record.subject.replace(
    /^(feat|fix|refactor|perf|build|ci|docs|test|chore)(\([^)]*\))?!?:\s*/i,
    ""
  )
  const group = /^(fix|perf)(\(|:|!)/i.test(record.subject)
    ? "Fixed"
    : /^feat(\(|:|!)/i.test(record.subject)
      ? "Added"
      : "Changed"
  const short = record.sha.slice(0, 7)
  groups[group].push(
    `- ${normalized} ([${short}](https://github.com/${repository}/commit/${record.sha}))`
  )
}

const heading = channel === "alpha" ? `Codevisor ${version} Alpha` : `Codevisor ${version}`
const sections = Object.entries(groups)
  .filter(([, entries]) => entries.length > 0)
  .map(([name, entries]) => `## ${name}\n\n${entries.join("\n")}`)
const notes = `# ${heading}\n\n${sections.join("\n\n")}\n`
writeFileSync(output, notes)
console.log(`Wrote ${records.length} commits from ${baseTag ?? "repository start"} to ${output}`)

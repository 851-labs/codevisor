#!/usr/bin/env node

import { execFileSync } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import {
  generateReleaseNotes,
  listPublishedReleases,
  shouldRefreshReleaseBody
} from "./generate-release-notes.mjs"

const parseArguments = (argv) => {
  const options = { apply: false, force: false }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === "--apply") {
      options.apply = true
    } else if (argument === "--force") {
      options.force = true
    } else if (
      ["--repository", "--output-dir", "--cwd", "--start-tag", "--max-releases"].includes(argument)
    ) {
      const value = argv[index + 1]
      if (value === undefined) {
        throw new Error(`${argument} requires a value`)
      }
      options[argument.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value
      index += 1
    } else {
      throw new Error(`Unknown argument: ${argument}`)
    }
  }
  return options
}

const editRelease = ({ repository, tag, notesFile, cwd }) => {
  execFileSync("gh", ["release", "edit", tag, "--repo", repository, "--notes-file", notesFile], {
    cwd,
    env: process.env,
    stdio: "inherit"
  })
}

export const backfillReleaseNotes = async ({
  repository = process.env.GITHUB_REPOSITORY ?? "851-labs/codevisor",
  outputDir = "dist/release-notes-backfill",
  cwd = process.cwd(),
  apply = false,
  force = false,
  startTag,
  maxReleases,
  generate = generateReleaseNotes,
  edit = editRelease,
  listReleases = listPublishedReleases
} = {}) => {
  const allReleases = listReleases({ repository, cwd })
    .filter((release) => release.published_at !== null)
    .sort(
      (left, right) =>
        new Date(left.published_at).getTime() - new Date(right.published_at).getTime()
    )
  if (allReleases.length === 0) {
    throw new Error(`No published releases found for ${repository}`)
  }

  let startIndex = 0
  if (startTag !== undefined && startTag.length > 0) {
    startIndex = allReleases.findIndex((release) => release.tag_name === startTag)
    if (startIndex === -1) {
      throw new Error(`Start tag is not a published release: ${startTag}`)
    }
  }
  const parsedMaximum = maxReleases === undefined ? undefined : Number(maxReleases)
  if (parsedMaximum !== undefined && (!Number.isInteger(parsedMaximum) || parsedMaximum < 1)) {
    throw new Error("--max-releases must be a positive integer")
  }
  const releases = allReleases.slice(
    startIndex,
    parsedMaximum === undefined ? undefined : startIndex + parsedMaximum
  )

  const absoluteOutputDir = resolve(cwd, outputDir)
  mkdirSync(absoluteOutputDir, { recursive: true })
  const manifest = [
    `# Codevisor release-note backfill ${apply ? "apply" : "preview"}`,
    "",
    `Repository: ${repository}`,
    `Range: ${releases[0].tag_name} through ${releases.at(-1).tag_name}`,
    ""
  ]
  let previousTag = startIndex === 0 ? undefined : allReleases[startIndex - 1].tag_name
  let updated = 0
  let skipped = 0
  let failure

  for (const [index, release] of releases.entries()) {
    const tag = release.tag_name
    const alreadyComplete = !shouldRefreshReleaseBody(release.body ?? "")
    if (alreadyComplete && !force) {
      console.log(`Skipping ${tag}; it already has model-generated v1 notes.`)
      manifest.push(`- ${tag}: skipped (already current)`)
      skipped += 1
      previousTag = tag
      continue
    }

    const safeTag = tag.replace(/[^A-Za-z0-9_.-]/g, "-")
    const notesFile = join(absoluteOutputDir, `${String(index + 1).padStart(3, "0")}-${safeTag}.md`)
    try {
      const result = await generate({
        tag,
        target: tag,
        previousTag,
        repository,
        output: notesFile,
        cwd,
        requireSummary: true
      })
      if (apply) {
        edit({ repository, tag, notesFile: result.outputPath, cwd })
      }
      console.log(`${apply ? "Updated" : "Previewed"} ${tag} (${result.commits.length} changes).`)
      manifest.push(
        `- ${tag}: ${apply ? "updated" : "previewed"} (${result.commits.length} changes, ${notesFile})`
      )
      updated += 1
    } catch (error) {
      failure = new Error(`Stopped at ${tag}: ${error.message}`, { cause: error })
      manifest.push(`- ${tag}: failed (${error.message})`)
      break
    }
    previousTag = tag
  }

  const manifestPath = join(absoluteOutputDir, "README.md")
  manifest.push("", `Completed: ${updated}; skipped: ${skipped}; total: ${releases.length}`, "")
  writeFileSync(manifestPath, manifest.join("\n"))

  if (failure !== undefined) {
    throw failure
  }
  return {
    releases: releases.length,
    availableReleases: allReleases.length,
    updated,
    skipped,
    manifestPath
  }
}

const main = async () => {
  const options = parseArguments(process.argv.slice(2))
  const result = await backfillReleaseNotes(options)
  console.log(
    `${options.apply ? "Applied" : "Generated previews for"} ${result.updated} releases; skipped ${result.skipped}.`
  )
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`error: ${error.message}`)
    process.exitCode = 1
  })
}

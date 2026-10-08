import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, rm, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"

import { isPathSafe, sanitizeName, SkillsError } from "./skills-store.js"

export { parseSkillSource, type ParsedSkillSource } from "./skills-source.js"

/// Download skills published via RFC 8615 well-known endpoints into a
/// staging directory. Mirrors the `npx skills` provider: probes
/// `.well-known/agent-skills/index.json` (then the legacy
/// `.well-known/skills/index.json`) against both the given URL path and the
/// site origin, and supports both index formats — legacy per-file listings
/// and v0.2.0 single artifacts (`skill-md` files or zip/tar.gz archives with
/// sha256 digests).
export const materializeWellKnownSkills = async (
  sourceUrl: string,
  staging: string
): Promise<void> => {
  const trimmed = sourceUrl.replace(/\/+$/, "")
  const origin = new URL(trimmed).origin
  const bases = [...new Set([trimmed, origin])]
  const wellKnownPaths = [".well-known/agent-skills", ".well-known/skills"]

  let entries: ReadonlyArray<Record<string, unknown>> | undefined
  let indexDir: string | undefined
  for (const base of bases) {
    for (const path of wellKnownPaths) {
      const indexUrl = `${base}/${path}/index.json`
      try {
        const response = await fetch(indexUrl)
        if (!response.ok) continue
        const parsed = (await response.json()) as { skills?: unknown }
        if (!Array.isArray(parsed.skills)) continue
        entries = parsed.skills.filter(
          (entry): entry is Record<string, unknown> => entry !== null && typeof entry === "object"
        )
        indexDir = `${base}/${path}`
        break
      } catch {
        // Unreachable host or invalid JSON at this candidate — try the next.
      }
    }
    if (entries !== undefined) break
  }
  if (entries === undefined || indexDir === undefined || entries.length === 0) {
    throw new SkillsError(
      `No skills found at ${sourceUrl} — the site needs a .well-known/agent-skills/index.json`,
      "invalid"
    )
  }

  for (const entry of entries) {
    const name = typeof entry["name"] === "string" ? entry["name"] : undefined
    if (name === undefined || name === "") continue
    const directory = join(staging, sanitizeName(name))
    try {
      if (Array.isArray(entry["files"])) {
        // Legacy format: fetch each listed file from <indexDir>/<name>/.
        await mkdir(directory, { recursive: true })
        for (const file of entry["files"]) {
          if (typeof file !== "string") continue
          const destination = join(directory, file)
          if (!isPathSafe(directory, destination)) continue
          const response = await fetch(`${indexDir}/${encodeURIComponent(name)}/${file}`)
          if (!response.ok) throw new Error(`Failed to fetch ${file}`)
          await mkdir(dirname(destination), { recursive: true })
          await writeFile(destination, Buffer.from(await response.arrayBuffer()))
        }
        continue
      }
      const artifactUrl = typeof entry["url"] === "string" ? entry["url"] : undefined
      if (artifactUrl === undefined) continue
      const response = await fetch(new URL(artifactUrl, `${indexDir}/`))
      if (!response.ok) throw new Error(`Failed to fetch ${artifactUrl}`)
      const bytes = Buffer.from(await response.arrayBuffer())
      const digest = entry["digest"]
      if (typeof digest === "string" && digest.startsWith("sha256:")) {
        const actual = `sha256:${createHash("sha256").update(bytes).digest("hex")}`
        if (actual !== digest) throw new Error("Artifact digest mismatch")
      }
      await mkdir(directory, { recursive: true })
      if (entry["type"] === "skill-md") {
        await writeFile(join(directory, "SKILL.md"), bytes)
        continue
      }
      await extractArchive(bytes, directory)
    } catch {
      // A broken entry never poisons the rest of the index; the skill is
      // simply absent from discovery.
      await rm(directory, { force: true, recursive: true })
    }
  }
}

/// Extract a zip or tar.gz artifact (detected by magic bytes) with the
/// system tools — bsdtar and unzip both sanitize `..`/absolute entries, and
/// discovery re-validates every path before anything reaches the store.
const extractArchive = async (bytes: Buffer, directory: string): Promise<void> => {
  const artifact = join(directory, `.artifact-${randomUUIDForArtifact()}`)
  await writeFile(artifact, bytes)
  try {
    const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b
    const isGzip = bytes[0] === 0x1f && bytes[1] === 0x8b
    if (!isZip && !isGzip) throw new Error("Unsupported archive format")
    const [command, args] = isZip
      ? ["unzip", ["-q", "-o", artifact, "-d", directory]]
      : ["tar", ["-xzf", artifact, "-C", directory]]
    await new Promise<void>((resolvePromise, rejectPromise) => {
      const child = spawn(command as string, args as Array<string>)
      const stderr: Array<string> = []
      child.stderr.setEncoding("utf8")
      child.stderr.on("data", (chunk: string) => stderr.push(chunk))
      /* v8 ignore next -- spawn-level failures (tool missing) need an environment tests can't fake. */
      child.on("error", (cause) => rejectPromise(cause))
      child.on("close", (code) => {
        if (code === 0) {
          resolvePromise()
          return
        }
        const reason = stderr.join("").trim()
        /* v8 ignore next -- tar and unzip always write a failure reason to stderr; exit-code fallback is a backstop. */
        rejectPromise(new Error(reason === "" ? `extraction exited with ${code}` : reason))
      })
    })
  } finally {
    await rm(artifact, { force: true })
  }
}

/* v8 ignore next 2 -- trivial indirection so artifact temp names stay unique without Date/Math.random. */
const randomUUIDForArtifact = (): string =>
  createHash("sha256").update(process.hrtime.bigint().toString()).digest("hex").slice(0, 12)

/// Default clone: shallow, optionally pinned to a branch or tag, with
/// interactive prompts disabled so a bad URL fails fast instead of hanging.
export const cloneSkillSource = (
  url: string,
  ref: string | undefined,
  destination: string
): Promise<void> =>
  new Promise((resolvePromise, rejectPromise) => {
    const args = [
      "clone",
      "--depth",
      "1",
      ...(ref === undefined ? [] : ["--branch", ref]),
      url,
      destination
    ]
    const child = spawn("git", args, {
      env: {
        ...process.env,
        GIT_ASKPASS: "true",
        GIT_SSH_COMMAND: process.env["GIT_SSH_COMMAND"] ?? "ssh -oBatchMode=yes",
        GIT_TERMINAL_PROMPT: "0"
      }
    })
    const stderr: Array<string> = []
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk: string) => stderr.push(chunk))
    /* v8 ignore next -- spawn-level failures (git missing) need an environment tests can't fake. */
    child.on("error", (cause) => rejectPromise(cause))
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise()
        return
      }
      const reason = stderr.join("").trim()
      /* v8 ignore next -- git always writes a failure reason to stderr; exit-code fallback is a backstop. */
      rejectPromise(new Error(reason === "" ? `git clone exited with ${code}` : reason))
    })
  })

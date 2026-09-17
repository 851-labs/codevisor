// Packages the locally built GhosttyKit.xcframework as the shared development
// artifact: one tarball plus its SHA-256 sidecar. The archive path is the only
// thing written to stdout — build-release-artifacts.yml captures it in a
// command substitution — so every diagnostic has to go to stderr.
import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { createReadStream, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { basename, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
// Left exactly as given: the workflow passes a repo-relative "dist/release"
// and then takes the basename of whatever path this prints.
const outputDirectory = process.argv[2] || `${root}/dist/release`
const framework = `${root}/apps/macos/Frameworks/GhosttyKit.xcframework`

// build-ghostty.sh owns the stamp format; --print-stamp reports the stamp the
// current sources would produce. A failure here aborts with its exit status.
const stampRun = spawnSync(`${root}/apps/macos/scripts/build-ghostty.sh`, ["--print-stamp"], {
  encoding: "utf8",
  stdio: ["inherit", "pipe", "inherit"]
})
if (stampRun.error) throw stampRun.error
if (stampRun.status !== 0) process.exit(stampRun.status ?? 1)
const stamp = stampRun.stdout.replace(/\n+$/, "")

function isDirectory(path: string): boolean {
  return statSync(path, { throwIfNoEntry: false })?.isDirectory() ?? false
}

// A missing sidecar reads as an empty stamp, which can never match.
function readStamp(path: string): string {
  try {
    return readFileSync(path, "utf8").replace(/\n+$/, "")
  } catch {
    return ""
  }
}

// Never package a stale framework: the sidecar build-ghostty.sh wrote has to
// match the stamp it reports now.
if (!isDirectory(framework) || readStamp(`${framework}/.codevisor-stamp`) !== stamp) {
  console.error(`GhosttyKit.xcframework is missing or does not match ${stamp}`)
  process.exit(1)
}

mkdirSync(outputDirectory, { recursive: true })
const archive = `${outputDirectory}/GhosttyKit-${stamp}.tar.gz`
// COPYFILE_DISABLE keeps tar from adding ._ AppleDouble members, and -h
// follows the xcframework's symlinks so the archive stands on its own.
const tarRun = spawnSync(
  "/usr/bin/tar",
  ["-C", dirname(framework), "-chzf", archive, basename(framework)],
  { env: { ...process.env, COPYFILE_DISABLE: "1" }, stdio: "inherit" }
)
if (tarRun.error) throw tarRun.error
if (tarRun.status !== 0) process.exit(tarRun.status ?? 1)

// The digest `shasum -a 256` produced, streamed so a multi-hundred-megabyte
// archive never has to land in memory, written in the same two-space format.
const digest = createHash("sha256")
for await (const chunk of createReadStream(archive)) digest.update(chunk)
writeFileSync(`${archive}.sha256`, `${digest.digest("hex")}  ${basename(archive)}\n`)

console.log(archive)

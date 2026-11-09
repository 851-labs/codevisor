import { createHash } from "node:crypto"
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join, relative } from "node:path"

import { withArtifactLock } from "./artifact-lock.ts"
import { captureCommand, runCommand } from "./commands.ts"
import { pathExists } from "./files.ts"

const inputsKeyFile = "inputs.sha256"

export async function ensureDevServerArchive(options: {
  readonly repoRoot: string
  readonly archiveRoot: string
}): Promise<string> {
  const { repoRoot, archiveRoot } = options
  const target = (
    await captureCommand(join(repoRoot, "scripts/release/detect-target.sh"), [])
  ).trim()
  const archive = join(archiveRoot, `codevisor-server-${target}.tar.gz`)
  const key = await serverInputsKey(repoRoot, target)
  if ((await cachedKey(archiveRoot)) === key && (await pathExists(archive))) return archive

  await buildServerArchive(repoRoot, archiveRoot, target)
  await writeFile(join(archiveRoot, inputsKeyFile), key)
  return archive
}

export async function serverInputsKey(repoRoot: string, target: string): Promise<string> {
  const hash = createHash("sha256").update(`${target}\n`)
  for (const path of await serverInputs(repoRoot, target)) {
    hash.update(`${relative(repoRoot, path)}\n`)
    hash.update(await readFile(path))
  }
  return hash.digest("hex")
}

function cachedKey(archiveRoot: string): Promise<string> {
  return readFile(join(archiveRoot, inputsKeyFile), "utf8").catch(() => "")
}

async function buildServerArchive(
  repoRoot: string,
  archiveRoot: string,
  target: string
): Promise<void> {
  const node = await ensureReleaseNode(repoRoot, target)
  await mkdir(archiveRoot, { recursive: true })
  const serverJs = join(archiveRoot, "server-js.tar.gz")
  try {
    await runScript(repoRoot, "scripts/release/package-server-js.sh", [serverJs])
    await runScript(
      repoRoot,
      "scripts/release/build-server-archive.sh",
      ["dev", archiveRoot, target],
      {
        CODEVISOR_PREBUILT_SERVER_JS: serverJs,
        CODEVISOR_RELEASE_NODE: join(node, "bin", "node"),
        npm_config_nodedir: node
      }
    )
  } finally {
    await rm(serverJs, { force: true })
  }
}

async function ensureReleaseNode(repoRoot: string, target: string): Promise<string> {
  const version = (await readFile(join(repoRoot, ".node-version"), "utf8")).trim()
  const name = `node-v${version}-${target}`
  const root = join(homedir(), ".codevisor-development", "artifacts", "node")
  const install = join(root, name)
  if (await pathExists(join(install, "bin", "node"))) return install

  await withArtifactLock(join(root, ".lock"), async () => {
    if (await pathExists(join(install, "bin", "node"))) return
    await installReleaseNode(root, name, `https://nodejs.org/dist/v${version}`)
  })
  return install
}

async function installReleaseNode(root: string, name: string, base: string): Promise<void> {
  const archive = Buffer.from(await (await download(`${base}/${name}.tar.gz`)).arrayBuffer())
  const checksums = await (await download(`${base}/SHASUMS256.txt`)).text()
  const expected = checksums
    .split("\n")
    .find((line) => line.endsWith(`  ${name}.tar.gz`))
    ?.split(" ")[0]
  if (expected !== createHash("sha256").update(archive).digest("hex")) {
    throw new Error(`${name}.tar.gz doesn't match its published SHA-256`)
  }

  const staging = await mkdtemp(join(root, `${name}.pending-`))
  try {
    await writeFile(join(staging, "node.tar.gz"), archive)
    await runCommand("tar", ["-xzf", join(staging, "node.tar.gz"), "-C", staging])
    await rename(join(staging, name), join(root, name))
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

async function download(url: string): Promise<Response> {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`${url} answered ${response.status}`)
  return response
}

async function serverInputs(repoRoot: string, target: string): Promise<Array<string>> {
  const packages = (await readdir(join(repoRoot, "packages"))).toSorted(byCodeUnit)
  const roots = [
    join(repoRoot, "apps/server/dist"),
    join(repoRoot, "patches"),
    ...packages.map((name) => join(repoRoot, "packages", name, "dist"))
  ]
  const singles = [
    join(repoRoot, "package.json"),
    join(repoRoot, "bun.lock"),
    join(repoRoot, ".node-version"),
    join(repoRoot, "apps/server/package.json"),
    join(repoRoot, "packages/net/native", target, "codevisor_net.node"),
    ...packages.map((name) => join(repoRoot, "packages", name, "package.json"))
  ]
  const files = await existing(singles)
  for (const root of roots) files.push(...(await filesUnder(root)))
  return files
}

async function existing(paths: ReadonlyArray<string>): Promise<Array<string>> {
  const present = await Promise.all(paths.map((path) => pathExists(path)))
  return paths.filter((_, index) => present[index])
}

async function filesUnder(root: string): Promise<Array<string>> {
  if (!(await pathExists(root))) return []

  const entries = await readdir(root, { recursive: true, withFileTypes: true })
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => join(entry.parentPath, entry.name))
    .toSorted(byCodeUnit)
}

function runScript(
  repoRoot: string,
  script: string,
  args: ReadonlyArray<string>,
  environment: Record<string, string> = {}
): Promise<void> {
  return runCommand(join(repoRoot, script), args, {
    cwd: repoRoot,
    env: { ...process.env, ...environment }
  })
}

function byCodeUnit(a: string, b: string): number {
  if (a < b) return -1
  return a > b ? 1 : 0
}

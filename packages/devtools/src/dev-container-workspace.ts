import { createHash, type Hash } from "node:crypto"
import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { pathExists } from "./files.ts"

export interface SyncedWorkspace {
  readonly appRoot: string
  readonly changed: boolean
}

const workspaceRoots = ["packages", "apps", "plugins"]
const packageRuntime = ["dist", "native", "resources", "server.json"]
const packageKeep = ["package.json", ...packageRuntime]
const rootKeep = [
  "package.json",
  "bun.lock",
  "bun.lockb",
  ".npmrc",
  "bunfig.toml",
  "patches",
  "plugins/popular.json"
]

export async function syncLinuxWorkspace(
  repoRoot: string,
  containerRoot: string
): Promise<SyncedWorkspace> {
  const appRoot = join(containerRoot, "app")
  const packageDirectories = await workspacePackageDirectories(repoRoot)
  const signature = await workspaceSignature(repoRoot, packageDirectories)
  const signaturePath = join(containerRoot, "app.signature")
  if (await isUpToDate(signaturePath, signature, appRoot)) return { appRoot, changed: false }

  await mkdir(appRoot, { recursive: true })
  await copyRootFiles(repoRoot, appRoot)
  await copyPackageRuntimes(repoRoot, appRoot, packageDirectories)
  await removeDeletedPackages(appRoot, packageDirectories)
  await writeFile(signaturePath, signature)
  return { appRoot, changed: true }
}

async function isUpToDate(
  signaturePath: string,
  signature: string,
  appRoot: string
): Promise<boolean> {
  if (!(await pathExists(signaturePath))) return false
  if ((await readFile(signaturePath, "utf8")) !== signature) return false

  return pathExists(join(appRoot, "package.json"))
}

async function copyRootFiles(repoRoot: string, appRoot: string): Promise<void> {
  for (const name of rootKeep) {
    await rm(join(appRoot, name), { recursive: true, force: true })
    await copyIfPresent(join(repoRoot, name), join(appRoot, name))
  }
}

async function copyPackageRuntimes(
  repoRoot: string,
  appRoot: string,
  packageDirectories: ReadonlyArray<string>
): Promise<void> {
  for (const directory of packageDirectories) {
    const target = join(appRoot, directory)
    await clearAllButNodeModules(target)
    await mkdir(target, { recursive: true })
    for (const name of packageKeep)
      await copyIfPresent(join(repoRoot, directory, name), join(target, name))
  }
}

async function clearAllButNodeModules(target: string): Promise<void> {
  if (!(await pathExists(target))) return

  for (const entry of await readdir(target)) {
    if (entry !== "node_modules") await rm(join(target, entry), { recursive: true, force: true })
  }
}

async function removeDeletedPackages(
  appRoot: string,
  packageDirectories: ReadonlyArray<string>
): Promise<void> {
  for (const root of workspaceRoots) {
    const rootPath = join(appRoot, root)
    if (!(await pathExists(rootPath))) continue

    for (const entry of await readdir(rootPath)) {
      const path = join(root, entry)
      if (!packageDirectories.includes(path) && !rootKeep.includes(path)) {
        await rm(join(appRoot, path), { recursive: true, force: true })
      }
    }
  }
}

async function copyIfPresent(from: string, to: string): Promise<void> {
  if (await pathExists(from)) await cp(from, to, { recursive: true, force: true })
}

async function workspacePackageDirectories(repoRoot: string): Promise<Array<string>> {
  const directories: Array<string> = []
  for (const root of workspaceRoots) {
    const rootPath = join(repoRoot, root)
    if (!(await pathExists(rootPath))) continue

    for (const entry of await readdir(rootPath, { withFileTypes: true })) {
      if (entry.isDirectory() && (await pathExists(join(rootPath, entry.name, "package.json")))) {
        directories.push(join(root, entry.name))
      }
    }
  }
  return directories
}

async function workspaceSignature(
  repoRoot: string,
  packageDirectories: ReadonlyArray<string>
): Promise<string> {
  const hash = createHash("sha256")
  for (const name of rootKeep) {
    const path = join(repoRoot, name)
    if (await pathExists(path)) await hashTree(hash, path, name)
  }
  for (const directory of packageDirectories.toSorted(byCodeUnit)) {
    hash.update(directory)
    hash.update(await readFile(join(repoRoot, directory, "package.json")))
    for (const output of packageRuntime) {
      const path = join(repoRoot, directory, output)
      if (await pathExists(path)) hash.update(String(await newestMtime(path)))
    }
  }
  return hash.digest("hex")
}

async function hashTree(hash: Hash, path: string, name: string): Promise<void> {
  hash.update(name)
  if (!(await stat(path)).isDirectory()) {
    hash.update(await readFile(path))
    return
  }
  for (const entry of (await readdir(path)).toSorted(byCodeUnit))
    await hashTree(hash, join(path, entry), join(name, entry))
}

async function newestMtime(path: string): Promise<number> {
  const info = await stat(path)
  if (!info.isDirectory()) return info.mtimeMs

  let newest = info.mtimeMs
  for (const entry of await readdir(path))
    newest = Math.max(newest, await newestMtime(join(path, entry)))
  return newest
}

function byCodeUnit(a: string, b: string): number {
  if (a < b) return -1
  return a > b ? 1 : 0
}

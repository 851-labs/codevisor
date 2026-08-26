/// Linux workspace assembly for the containerized dev remotes — the
/// dist/manifest subset copied under tmp/container/app that the container
/// installs its own Linux node_modules into.
import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import { join } from "node:path"
import { pathExists } from "./dev-shared.mjs"

/// The workspace subset a Linux container needs to run `dist/main.js`:
/// built output plus manifests, never sources or macOS node_modules. The
/// container installs its own Linux node_modules into the copy.
const WORKSPACE_ROOTS = ["packages", "apps"]
const PACKAGE_KEEP = ["package.json", "dist"]
const ROOT_KEEP = ["package.json", "bun.lock", "bun.lockb", ".npmrc", "bunfig.toml", "patches"]

const copyIfPresent = async (from, to) => {
  if (!(await pathExists(from))) return false
  await cp(from, to, { recursive: true, force: true })
  return true
}

const workspacePackageDirectories = async (repoRoot) => {
  const directories = []
  for (const root of WORKSPACE_ROOTS) {
    const rootPath = join(repoRoot, root)
    if (!(await pathExists(rootPath))) continue
    for (const entry of await readdir(rootPath, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue
      if (await pathExists(join(rootPath, entry.name, "package.json"))) {
        directories.push(join(root, entry.name))
      }
    }
  }
  return directories
}

/// A cheap change signature over every manifest and dist mtime: when it
/// matches the previous sync, the copy (and the container's install) can be
/// skipped entirely, so rig restarts stay fast.
const workspaceSignature = async (repoRoot, packageDirectories) => {
  const hash = createHash("sha256")
  for (const name of ROOT_KEEP) {
    const path = join(repoRoot, name)
    if (!(await pathExists(path))) continue
    hash.update(name)
    hash.update(await readFile(path))
  }
  for (const directory of packageDirectories.toSorted()) {
    hash.update(directory)
    hash.update(await readFile(join(repoRoot, directory, "package.json")))
    const dist = join(repoRoot, directory, "dist")
    if (await pathExists(dist)) {
      const newest = await newestMtime(dist)
      hash.update(String(newest))
    }
  }
  return hash.digest("hex")
}

const newestMtime = async (path) => {
  const info = await stat(path)
  if (!info.isDirectory()) return info.mtimeMs
  let newest = info.mtimeMs
  for (const entry of await readdir(path)) {
    newest = Math.max(newest, await newestMtime(join(path, entry)))
  }
  return newest
}

/// Assembles (or refreshes) the Linux workspace copy under
/// tmp/container/app. Returns the absolute path to the copy.
export async function syncLinuxWorkspace(repoRoot, containerRoot) {
  const appRoot = join(containerRoot, "app")
  const packageDirectories = await workspacePackageDirectories(repoRoot)
  const signature = await workspaceSignature(repoRoot, packageDirectories)
  const signaturePath = join(containerRoot, "app.signature")
  const previous = (await pathExists(signaturePath))
    ? await readFile(signaturePath, "utf8")
    : undefined
  if (previous === signature && (await pathExists(join(appRoot, "package.json")))) {
    return { appRoot, changed: false }
  }
  await mkdir(appRoot, { recursive: true })
  for (const name of ROOT_KEEP) {
    await copyIfPresent(join(repoRoot, name), join(appRoot, name))
  }
  for (const directory of packageDirectories) {
    const target = join(appRoot, directory)
    // Refresh the copied members but PRESERVE node_modules: the Linux
    // install nests workspace links and conflict-resolved deps inside
    // package dirs, and a refresh with an unchanged lockfile never
    // reinstalls them.
    if (await pathExists(target)) {
      for (const entry of await readdir(target)) {
        if (entry === "node_modules") continue
        await rm(join(target, entry), { recursive: true, force: true })
      }
    }
    await mkdir(target, { recursive: true })
    for (const name of PACKAGE_KEEP) {
      await copyIfPresent(join(repoRoot, directory, name), join(target, name))
    }
  }
  // Package dirs that no longer exist in the workspace disappear whole.
  for (const root of WORKSPACE_ROOTS) {
    const rootPath = join(appRoot, root)
    if (!(await pathExists(rootPath))) continue
    for (const entry of await readdir(rootPath)) {
      if (!packageDirectories.includes(join(root, entry))) {
        await rm(join(rootPath, entry), { recursive: true, force: true })
      }
    }
  }
  await writeFile(signaturePath, signature)
  return { appRoot, changed: true }
}

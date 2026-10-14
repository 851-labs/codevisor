import { readdir, readFile, stat } from "node:fs/promises"
import { createRequire } from "node:module"
import { join, relative, resolve } from "node:path"
import { pathToFileURL } from "node:url"

const DEPENDENCY_FIELDS = ["dependencies", "optionalDependencies"]

const readManifest = async (path) => JSON.parse(await readFile(path, "utf8"))

const defaultLoad = (name, manifestPath) => {
  createRequire(manifestPath)(name)
}

export async function workspaceDirectories(repoRoot, workspaces) {
  const perPattern = await Promise.all(
    workspaces.map(async (pattern) => {
      if (!pattern.endsWith("/*")) {
        throw new Error(`unsupported workspace pattern: ${pattern}`)
      }
      const root = join(repoRoot, pattern.slice(0, -2))
      const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
      const candidates = entries.filter((entry) => entry.isDirectory())
      const hasManifest = await Promise.all(
        candidates.map((entry) =>
          stat(join(root, entry.name, "package.json")).then(
            () => true,
            () => false
          )
        )
      )
      return candidates
        .filter((_, index) => hasManifest[index])
        .map((entry) => join(root, entry.name))
    })
  )
  return perPattern.flat()
}

export async function verifyTrustedDependencies(repoRoot, { load = defaultLoad } = {}) {
  const rootManifest = await readManifest(join(repoRoot, "package.json"))
  const directories = await workspaceDirectories(repoRoot, rootManifest.workspaces ?? [])
  const manifests = await Promise.all(
    directories.map(async (directory) => ({
      directory,
      manifest: await readManifest(join(directory, "package.json"))
    }))
  )
  const checks = []
  const undeclared = []
  for (const name of rootManifest.trustedDependencies ?? []) {
    let declared = false
    for (const { directory, manifest } of manifests) {
      if (!DEPENDENCY_FIELDS.some((field) => manifest[field]?.[name] !== undefined)) continue
      declared = true
      const workspace = relative(repoRoot, directory)
      try {
        load(name, join(directory, "package.json"))
        checks.push({ name, workspace })
      } catch (error) {
        checks.push({
          name,
          workspace,
          error: error instanceof Error ? error.message : String(error)
        })
      }
    }
    if (!declared) undeclared.push(name)
  }
  return {
    checks,
    undeclared,
    failures: checks.filter((check) => check.error !== undefined)
  }
}

const isMain =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href

if (isMain) {
  const repoRoot = resolve(process.argv[2] ?? process.cwd())
  const result = await verifyTrustedDependencies(repoRoot)
  for (const check of result.checks) {
    const status = check.error === undefined ? "ok  " : "FAIL"
    const detail = check.error === undefined ? "" : `: ${check.error.split("\n")[0]}`
    console.log(`  ${status} ${check.name} from ${check.workspace}${detail}`)
  }
  for (const name of result.undeclared) {
    console.warn(`  warning: trusted dependency ${name} is declared by no workspace`)
  }
  if (result.failures.length > 0) {
    console.error(
      `${result.failures.length} trusted dependenc${result.failures.length === 1 ? "y" : "ies"} failed to load`
    )
    process.exit(1)
  }
}

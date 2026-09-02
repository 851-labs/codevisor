import { accessSync, constants } from "node:fs"

/// Default executable locator. Plain names are searched on PATH; candidates
/// with a leading `/` or `~/` (harness `fallbackPaths`, e.g. a CLI bundled
/// inside a desktop app) are probed directly, `~` expanding via env.HOME.
/// Exported for tests only.
export const locateExecutableOnPath = (
  name: string,
  env: NodeJS.ProcessEnv
): string | undefined => {
  if (name.startsWith("/") || name.startsWith("~/")) {
    if (name.startsWith("~/") && env.HOME === undefined) {
      return undefined
    }
    const candidate = name.startsWith("~/") ? `${env.HOME}${name.slice(1)}` : name
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {
      return undefined
    }
  }
  const path = env.PATH ?? ""
  for (const directory of path.split(":")) {
    const candidate = `${directory}/${name}`
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {
      continue
    }
  }
  return undefined
}

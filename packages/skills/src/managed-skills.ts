import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

/// A skill shipped inside Codevisor and served by the gateway's `skills`
/// tool. `path` is its SKILL.md.
export interface PackagedSkill {
  readonly name: string
  /// One line for the `skills` tool description.
  readonly summary: string
  readonly path: string
}

export const attachingFilesSkill = (
  moduleDirectory = dirname(fileURLToPath(import.meta.url)),
  workingDirectory = process.cwd()
): PackagedSkill => {
  const name = "attaching-files"
  const path = [
    join(moduleDirectory, "..", "resources", name, "SKILL.md"),
    join(workingDirectory, "packages", "skills", "resources", name, "SKILL.md")
  ].find((candidate) => existsSync(candidate))
  if (path === undefined) throw new Error("Missing packaged attaching-files skill")
  return { name, path, summary: "send screenshots, recordings, and files to the user" }
}

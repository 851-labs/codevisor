import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

export interface PackagedSkill {
  readonly name: string
  readonly summary: string
  readonly path: string
  readonly composer?: string
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
  return {
    composer: "Send you screenshots, recordings, and files",
    name,
    path,
    summary: "send screenshots, recordings, and files to the user"
  }
}

import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import type { ManagedSkillSpec } from "./skills-manager.js"

export const managedAttachmentSkill = (
  moduleDirectory = dirname(fileURLToPath(import.meta.url)),
  workingDirectory = process.cwd()
): ManagedSkillSpec => {
  const directoryName = "attaching-files"
  const sourcePath = [
    join(moduleDirectory, "..", "resources", directoryName),
    join(workingDirectory, "packages", "skills", "resources", directoryName)
  ].find((path) => existsSync(join(path, "SKILL.md")))
  if (sourcePath === undefined) throw new Error("Missing packaged attaching-files skill")
  return { directoryName, sourcePath, enabled: true }
}

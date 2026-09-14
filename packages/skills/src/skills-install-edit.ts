import { readFile, realpath, writeFile } from "node:fs/promises"
import { join } from "node:path"
import type { SkillsInstallContext } from "./skills-install-context.js"
import { isPathSafe, parseFrontmatter, SkillsError } from "./skills-store.js"

export const makeSkillsEditOperations = (context: SkillsInstallContext) => {
  const { canonicalDir, canonicalSkillPath, installEverywhere, isManagedSkill, list } = context

  const documentPath = async (directoryName: string): Promise<string> => {
    const path = await canonicalSkillPath(directoryName)
    const file = await realpath(join(path, "SKILL.md"))
    if (!isPathSafe(await realpath(canonicalDir), file) || (await isManagedSkill(path))) {
      throw new SkillsError("Only user skills in the shared skills folder can be edited", "invalid")
    }
    return file
  }

  const read = async (directoryName: string) => ({
    content: await readFile(await documentPath(directoryName), "utf8")
  })

  const update = async (directoryName: string, request: { readonly content: string }) => {
    const file = await documentPath(directoryName)
    let data: Record<string, unknown>
    try {
      data = parseFrontmatter(request.content).data
    } catch {
      throw new SkillsError("The SKILL.md frontmatter is not valid YAML", "invalid")
    }
    if (
      typeof data["name"] !== "string" ||
      data["name"].trim() === "" ||
      typeof data["description"] !== "string" ||
      data["description"].trim() === ""
    ) {
      throw new SkillsError("Include a name and description in the SKILL.md frontmatter", "invalid")
    }
    await writeFile(file, request.content, "utf8")
    await installEverywhere([directoryName])
    return list()
  }

  return { read, update }
}

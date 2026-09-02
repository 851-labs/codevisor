import type { SkillsScan } from "@codevisor/api"
import { lstat, mkdir, writeFile } from "node:fs/promises"
import { basename, join, resolve } from "node:path"
import { assertSafeChild, type SkillsInstallContext } from "./skills-install-context.js"
import {
  copyDirectory,
  hasSkillFile,
  isDirectory,
  parseFrontmatter,
  pathsOverlap,
  readSkillDocument,
  sanitizeName,
  SkillsError
} from "./skills-store.js"

export interface ImportDirectoryResult {
  readonly outcome: "imported" | "conflict" | "selfImport"
  readonly directoryName: string
}

/// Copy one on-disk skill folder into the canonical store. Returns the
/// outcome instead of throwing on conflicts so multi-skill imports can
/// report per-skill results.
export const importDirectory = async (
  canonicalDir: string,
  source: string
): Promise<ImportDirectoryResult> => {
  const document = await readSkillDocument(source, basename(source))
  const directoryName = sanitizeName(
    document.invalid || document.name === "" ? basename(source) : document.name
  )
  const destination = assertSafeChild(canonicalDir, directoryName)
  // Never import a skill onto (or inside) itself — cleaning the
  // destination would destroy the source (installer.ts pathsOverlap skip).
  if (pathsOverlap(source, destination)) return { directoryName, outcome: "selfImport" }
  try {
    await lstat(destination)
    return { directoryName, outcome: "conflict" }
  } catch {
    // Destination free — proceed.
  }
  await copyDirectory(source, destination)
  return { directoryName, outcome: "imported" }
}

/// Creating skills from the editor and importing them from local folders.
export const makeSkillsCreateOperations = (context: SkillsInstallContext) => {
  const { canonicalDir, installEverywhere, list } = context

  const create = async (request: {
    readonly name: string
    readonly description: string
    readonly content?: string | undefined
  }): Promise<SkillsScan> => {
    const trimmedName = request.name.trim()
    if (trimmedName === "") throw new SkillsError("Skill name is required", "invalid")
    const description = request.description.trim()
    const pasted = request.content?.trim() ?? ""

    // Pasted content that already carries frontmatter is written verbatim
    // (its own name wins for the directory); otherwise frontmatter from the
    // form fields is prepended to whatever body we have.
    let skillFile: string
    let namingSource = trimmedName
    if (pasted.startsWith("---")) {
      skillFile = `${pasted}\n`
      try {
        const { data } = parseFrontmatter(skillFile)
        if (typeof data["name"] === "string" && data["name"] !== "") {
          namingSource = data["name"]
        }
      } catch {
        throw new SkillsError("The pasted SKILL.md frontmatter is not valid YAML", "invalid")
      }
    } else {
      const body =
        pasted !== ""
          ? pasted
          : [
              description === "" ? trimmedName : description,
              "",
              "## Instructions",
              "",
              "Describe the steps the agent should follow when this skill applies."
            ].join("\n")
      skillFile = [
        "---",
        `name: ${JSON.stringify(trimmedName)}`,
        `description: ${JSON.stringify(description === "" ? trimmedName : description)}`,
        "---",
        "",
        body,
        ""
      ].join("\n")
    }

    const directoryName = sanitizeName(namingSource)
    const path = assertSafeChild(canonicalDir, directoryName)
    try {
      await lstat(path)
      throw new SkillsError(`A skill named ${directoryName} already exists`, "conflict")
    } catch (cause) {
      if (cause instanceof SkillsError) throw cause
    }
    await mkdir(path, { recursive: true })
    await writeFile(join(path, "SKILL.md"), skillFile, "utf8")
    // New skills are immediately usable everywhere.
    await installEverywhere([directoryName])
    return list()
  }

  const importLocal = async (request: { readonly path: string }): Promise<SkillsScan> => {
    const source = resolve(request.path)
    if (!(await isDirectory(source))) {
      throw new SkillsError(`Not a directory: ${request.path}`, "invalid")
    }
    if (!(await hasSkillFile(source))) {
      throw new SkillsError(`No SKILL.md found in ${request.path}`, "invalid")
    }
    const { directoryName, outcome } = await importDirectory(canonicalDir, source)
    if (outcome === "conflict") {
      throw new SkillsError(`A skill named ${basename(source)} already exists`, "conflict")
    }
    if (outcome === "imported") await installEverywhere([directoryName])
    return list()
  }

  return { create, importLocal }
}

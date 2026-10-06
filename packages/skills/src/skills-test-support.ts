import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SkillsList } from "@codevisor/api"

import { makeSkillStore, type CloneSkillSource, type SkillStore } from "./skill-store.js"

export const directories: string[] = []

export const cleanupSkillsTests = (): void => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
}

export const makeHome = (): string => {
  const home = mkdtempSync(join(tmpdir(), "codevisor-skills-"))
  directories.push(home)
  return home
}

/// The test store lives beside the fake home's harness folders.
export const storeDir = (home: string): string => join(home, "store")

export const writeSkill = (
  dir: string,
  options: { readonly name?: string; readonly description?: string; readonly body?: string } = {}
): void => {
  mkdirSync(dir, { recursive: true })
  const frontmatter =
    options.name === undefined
      ? ""
      : `---\nname: ${options.name}\ndescription: ${options.description ?? "A test skill"}\n---\n`
  writeFileSync(join(dir, "SKILL.md"), `${frontmatter}${options.body ?? "Do the thing."}\n`)
}

export const manager = (
  home: string,
  options: { readonly clone?: CloneSkillSource } = {}
): SkillStore =>
  makeSkillStore({
    dir: storeDir(home),
    ...(options.clone === undefined ? {} : { overrides: { clone: options.clone } })
  })

export const storedSkill = (list: SkillsList, directoryName: string) => {
  const skill = list.skills.find((candidate) => candidate.directoryName === directoryName)
  if (skill === undefined) throw new Error(`missing skill ${directoryName}`)
  return skill
}

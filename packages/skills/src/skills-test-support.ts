import { makeAgentRuntime } from "@codevisor/agent-runtime"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeSkillsManager } from "./skills-manager.js"
import type { SkillsManager } from "./skills-manager.js"

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
  env: Record<string, string | undefined> = {}
): SkillsManager => makeSkillsManager({ agents: makeAgentRuntime({}), env, homedir: home })

export const globalSkill = (
  scan: Awaited<ReturnType<SkillsManager["list"]>>,
  directoryName: string
) => {
  const skill = scan.global.find((candidate) => candidate.directoryName === directoryName)
  if (skill === undefined) throw new Error(`missing global skill ${directoryName}`)
  return skill
}

export const group = (scan: Awaited<ReturnType<SkillsManager["list"]>>, harnessId: string) => {
  const found = scan.harnesses.find((candidate) => candidate.harnessId === harnessId)
  if (found === undefined) throw new Error(`missing harness group ${harnessId}`)
  return found
}

export const installState = (
  scan: Awaited<ReturnType<SkillsManager["list"]>>,
  directoryName: string,
  harnessId: string
): string | undefined =>
  globalSkill(scan, directoryName).installs.find((install) => install.harnessId === harnessId)
    ?.state

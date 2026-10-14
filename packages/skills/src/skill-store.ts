import { cp, mkdir, readdir, readFile, realpath, rename, rm, writeFile } from "node:fs/promises"
import { join, relative, resolve } from "node:path"

import type { Skill, SkillsList } from "@codevisor/api"

import { newSkillFile, validateSkillFile } from "./skill-file.js"
import { exists } from "./skill-import.js"
import { makeRemoteSkillOperations } from "./skill-store-remote.js"
import { cloneSkillSource } from "./skills-remote-source.js"
import {
  assertSafeChild,
  EXCLUDE_DIRS,
  hasSkillFile,
  isPathSafe,
  readSkillDocument,
  RESERVED_SKILL_NAMES,
  sanitizeName,
  SkillsError
} from "./skills-store.js"

export type CloneSkillSource = (
  url: string,
  ref: string | undefined,
  destination: string
) => Promise<void>

export interface SkillStoreConfig {
  readonly dir: string
  readonly overrides?: { readonly clone?: CloneSkillSource }
}

export interface SkillDocumentView {
  readonly content: string
  readonly path: string
  readonly files: ReadonlyArray<string>
}

export interface SkillStore {
  readonly dir: string
  readonly list: () => Promise<SkillsList>
  readonly read: (directoryName: string) => Promise<{ readonly content: string }>
  readonly update: (
    directoryName: string,
    request: { readonly content: string }
  ) => Promise<SkillsList>
  readonly create: (request: {
    readonly name: string
    readonly description: string
    readonly content?: string | undefined
  }) => Promise<SkillsList>
  readonly remove: (directoryName: string) => Promise<SkillsList>
  readonly discoverRemote: (request: { readonly source: string }) => Promise<{
    readonly skills: ReadonlyArray<{
      readonly name: string
      readonly directoryName: string
      readonly description?: string | undefined
      readonly alreadyExists: boolean
    }>
  }>
  readonly importRemote: (request: {
    readonly source: string
    readonly skillNames?: ReadonlyArray<string> | undefined
  }) => Promise<SkillsList>
  readonly replace: (directoryName: string, source: string) => Promise<void>
  readonly rename: (from: string, to: string) => Promise<void>
  readonly document: (directoryName: string) => Promise<SkillDocumentView | undefined>
  readonly subscribe: (listener: () => void) => () => void
}

const MAX_LISTED_FILES = 50

const supportingFiles = async (root: string): Promise<ReadonlyArray<string>> => {
  const files: Array<string> = []
  const walk = async (current: string): Promise<void> => {
    const entries = await readdir(current, { withFileTypes: true })
    for (const entry of entries.toSorted((a, b) => a.name.localeCompare(b.name))) {
      if (files.length >= MAX_LISTED_FILES) return
      const path = join(current, entry.name)
      if (entry.isDirectory()) {
        if (!EXCLUDE_DIRS.has(entry.name) && entry.name !== "node_modules") await walk(path)
        continue
      }
      const name = relative(root, path)
      if (name !== "SKILL.md") files.push(name)
    }
  }
  await walk(root)
  return files
}

export const makeSkillStore = (config: SkillStoreConfig): SkillStore => {
  const dir = resolve(config.dir)
  const listeners = new Set<() => void>()
  const emit = (): void => {
    for (const listener of listeners) listener()
  }

  const listSkills = async (): Promise<ReadonlyArray<Skill>> => {
    let entries
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      return []
    }
    const skills: Array<Skill> = []
    for (const entry of entries) {
      if (entry.name.startsWith(".") || !entry.isDirectory()) continue
      const path = join(dir, entry.name)
      if (!(await hasSkillFile(path))) continue
      const document = await readSkillDocument(path, entry.name)
      skills.push({
        directoryName: entry.name,
        name: document.name,
        path,
        ...(document.description === undefined ? {} : { description: document.description }),
        ...(document.invalid ? { invalid: true } : {})
      })
    }
    return skills.toSorted((a, b) => a.directoryName.localeCompare(b.directoryName))
  }

  const list = async (): Promise<SkillsList> => ({ dir, skills: await listSkills() })

  const skillFile = async (directoryName: string): Promise<string> => {
    const path = assertSafeChild(dir, directoryName)
    let file
    try {
      file = await realpath(join(path, "SKILL.md"))
    } catch {
      throw new SkillsError(`No skill named ${directoryName}`, "notFound")
    }
    if (!isPathSafe(await realpath(dir), file)) {
      throw new SkillsError(`No skill named ${directoryName}`, "notFound")
    }
    return file
  }

  const read = async (directoryName: string) => ({
    content: await readFile(await skillFile(directoryName), "utf8")
  })

  const update = async (directoryName: string, request: { readonly content: string }) => {
    const file = await skillFile(directoryName)
    validateSkillFile(request.content)
    await writeFile(file, request.content, "utf8")
    emit()
    return list()
  }

  const create = async (request: {
    readonly name: string
    readonly description: string
    readonly content?: string | undefined
  }) => {
    const { file, namingSource } = newSkillFile(request)
    const directoryName = sanitizeName(namingSource)
    if (RESERVED_SKILL_NAMES.has(directoryName)) {
      throw new SkillsError(`${directoryName} is a built-in Codevisor skill`, "conflict")
    }
    const path = assertSafeChild(dir, directoryName)
    if (await exists(path)) {
      throw new SkillsError(`A skill named ${directoryName} already exists`, "conflict")
    }
    await mkdir(path, { recursive: true })
    await writeFile(join(path, "SKILL.md"), file, "utf8")
    emit()
    return list()
  }

  const remove = async (directoryName: string) => {
    const path = assertSafeChild(dir, directoryName)
    if (!(await exists(path))) {
      throw new SkillsError(`No skill named ${directoryName}`, "notFound")
    }
    await rm(path, { force: true, recursive: true })
    emit()
    return list()
  }

  const replace = async (directoryName: string, source: string): Promise<void> => {
    const destination = assertSafeChild(dir, directoryName)
    await rm(destination, { force: true, recursive: true })
    await cp(source, destination, { recursive: true, verbatimSymlinks: true })
    emit()
  }

  const renameSkill = async (from: string, to: string): Promise<void> => {
    await rename(assertSafeChild(dir, from), assertSafeChild(dir, to))
    emit()
  }

  const document = async (directoryName: string): Promise<SkillDocumentView | undefined> => {
    let file
    try {
      file = await skillFile(directoryName)
    } catch {
      return undefined
    }
    const path = join(dir, directoryName)
    return {
      content: await readFile(file, "utf8"),
      files: await supportingFiles(path),
      path
    }
  }

  const remote = makeRemoteSkillOperations({
    clone: config.overrides?.clone ?? cloneSkillSource,
    dir,
    list,
    onImported: emit
  })

  return {
    create,
    dir,
    document,
    list,
    read,
    remove,
    rename: renameSkill,
    replace,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    update,
    ...remote
  }
}

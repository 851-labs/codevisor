import { createHash } from "node:crypto"

import { parseFrontmatter } from "@codevisor/skills"
import type { ReadResourceResult } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

export const SKILL_DOCUMENT = "SKILL.md"

export interface PluginSkillFile {
  readonly uri: string
  readonly digest: string
  readonly size: number
}

export interface PluginSkill {
  readonly uri: string
  readonly name: string
  readonly description?: string
  readonly frontmatter: Readonly<Record<string, unknown>>
  readonly files: ReadonlyArray<PluginSkillFile>
}

export interface VerifiedSkillFile {
  readonly text: string
  readonly binary: boolean
  readonly size: number
  readonly mimeType?: string
}

export const pluginSkills = (entries: ReadonlyArray<unknown>): ReadonlyArray<PluginSkill> => {
  const skills: PluginSkill[] = []
  for (const entry of entries) {
    const skill = pluginSkill(entry)
    if (skill !== undefined && !skills.some((known) => known.name === skill.name)) {
      skills.push(skill)
    }
  }
  return skills
}

export const pluginSkill = (entry: unknown): PluginSkill | undefined => {
  const parsed = SkillEntrySchema.safeParse(entry).data
  if (parsed === undefined) return undefined

  const { name, description } = parsed.frontmatter
  return {
    uri: parsed.uri,
    name,
    ...(description === undefined ? {} : { description }),
    frontmatter: parsed.frontmatter,
    files: parsed.resources
  }
}

export const supportingFiles = (skill: PluginSkill): ReadonlyArray<string> =>
  skill.files.filter((file) => file.uri !== skill.uri).map((file) => relativePath(skill, file.uri))

export const manifestFile = (skill: PluginSkill, path: string): PluginSkillFile | undefined => {
  const uri = path === SKILL_DOCUMENT ? skill.uri : `${skillRoot(skill)}/${path}`
  return skill.files.find((file) => file.uri === uri || file.uri === path)
}

export const verifiedSkillFile = (
  skill: PluginSkill,
  file: PluginSkillFile,
  result: ReadResourceResult
): VerifiedSkillFile | undefined => {
  const contents = result.contents.find((content) => content.uri === file.uri)
  if (contents === undefined) return undefined

  const bytes = contentBytes(contents)
  if (!matchesManifest(file, bytes)) return undefined

  const text = bytes.toString("utf8")
  if (file.uri === skill.uri && !frontmatterMatches(skill, text)) return undefined
  return {
    text,
    binary: !("text" in contents),
    size: bytes.length,
    ...(contents.mimeType === undefined ? {} : { mimeType: contents.mimeType })
  }
}

export const skillInstructions = (text: string): string => parseFrontmatter(text).content.trim()

const FileSchema = z.object({
  uri: z.string(),
  digest: z.string(),
  size: z.number().int().nonnegative()
})

const SkillEntrySchema = z.object({
  uri: z.string(),
  frontmatter: z.looseObject({ name: z.string().min(1), description: z.string().optional() }),
  resources: z.array(FileSchema)
})

type ResourceContents = ReadResourceResult["contents"][number]

const skillRoot = (skill: PluginSkill): string => skill.uri.slice(0, skill.uri.lastIndexOf("/"))

const relativePath = (skill: PluginSkill, uri: string): string => {
  const prefix = `${skillRoot(skill)}/`
  if (uri.startsWith(prefix)) return uri.slice(prefix.length)
  return uri
}

const contentBytes = (contents: ResourceContents): Buffer => {
  if ("text" in contents) return Buffer.from(contents.text, "utf8")
  return Buffer.from(contents.blob, "base64")
}

const matchesManifest = (file: PluginSkillFile, bytes: Buffer): boolean =>
  bytes.length === file.size && file.digest === sha256Digest(bytes)

const sha256Digest = (bytes: Buffer): string =>
  `sha256:${createHash("sha256").update(bytes).digest("hex")}`

const frontmatterMatches = (skill: PluginSkill, text: string): boolean => {
  const actual = documentFrontmatter(text)
  if (actual === undefined) return false

  const fields = new Set([...Object.keys(actual), ...Object.keys(skill.frontmatter)])
  return [...fields].every(
    (field) => JSON.stringify(actual[field]) === JSON.stringify(skill.frontmatter[field])
  )
}

const documentFrontmatter = (text: string): Record<string, unknown> | undefined => {
  try {
    return parseFrontmatter(text).data
  } catch {
    return undefined
  }
}

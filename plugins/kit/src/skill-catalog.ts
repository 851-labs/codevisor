import { createHash } from "node:crypto"

import type { Server } from "@modelcontextprotocol/sdk/server/index.js"

import { invalidParamsError } from "./plugin-protocol.js"
import { skillsGetRequest, skillsListRequest } from "./plugin-requests.js"
import type { ServedResource } from "./served-resources.js"

export interface SkillDefinition {
  name: string
  description: string
  instructions: string
  files: ReadonlyArray<SkillSupportFile>
}

export interface SkillSupportFile {
  path: string
  text: string
  mimeType: string
}

export interface SkillManifestEntry {
  uri: string
  digest: string
  size: number
}

export interface SkillEntry {
  uri: string
  frontmatter: Record<string, string>
  resources: ReadonlyArray<SkillManifestEntry>
}

export interface SkillCatalog {
  entries: ReadonlyArray<SkillEntry>
  resources: ReadonlyArray<ServedResource>
}

export const skillCacheTtlMs = 300_000

export const skillCatalog = (skills: ReadonlyArray<SkillDefinition>): SkillCatalog => {
  const served = skills.map(servedSkill)
  return {
    entries: served.map((skill) => skill.entry),
    resources: served.flatMap((skill) => skill.resources)
  }
}

export const registerSkills = (server: Server, catalog: SkillCatalog): void => {
  server.setRequestHandler(skillsListRequest, () => ({ ...cached(), skills: catalog.entries }))
  server.setRequestHandler(skillsGetRequest, (request) => ({
    ...cached(),
    skill: skillAt(catalog, request.params.uri)
  }))
}

interface ServedSkill {
  entry: SkillEntry
  resources: ReadonlyArray<ServedResource>
}

const servedSkill = (skill: SkillDefinition): ServedSkill => {
  const resources = [skillMarkdown(skill), ...skill.files.map((file) => supportFile(skill, file))]
  return {
    entry: {
      uri: skillUri(skill.name, skillFileName),
      frontmatter: { name: skill.name, description: skill.description },
      resources: resources.map(manifestEntry)
    },
    resources
  }
}

const skillFileName = "SKILL.md"

const skillMarkdown = (skill: SkillDefinition): ServedResource => ({
  uri: skillUri(skill.name, skillFileName),
  name: `${skill.name}/${skillFileName}`,
  mimeType: "text/markdown",
  text: `---\nname: ${JSON.stringify(skill.name)}\ndescription: ${JSON.stringify(skill.description)}\n---\n\n${skill.instructions}`
})

const supportFile = (skill: SkillDefinition, file: SkillSupportFile): ServedResource => ({
  uri: skillUri(skill.name, file.path),
  name: `${skill.name}/${file.path}`,
  mimeType: file.mimeType,
  text: file.text
})

const skillUri = (name: string, path: string): string => `skill://${name}/${path}`

const manifestEntry = (resource: ServedResource): SkillManifestEntry => {
  const bytes = Buffer.from(resource.text, "utf8")
  return {
    uri: resource.uri,
    digest: `sha256:${createHash("sha256").update(bytes).digest("hex")}`,
    size: bytes.byteLength
  }
}

const skillAt = (catalog: SkillCatalog, uri: string): SkillEntry => {
  const entry = catalog.entries.find((candidate) => candidate.uri === uri)
  if (entry === undefined) throw invalidParamsError(`Unknown skill: ${uri}`)

  return entry
}

const cached = () => ({ resultType: "complete", ttlMs: skillCacheTtlMs, cacheScope: "public" })

import type { McpServerRecord } from "@codevisor/db"
import { z } from "zod"

import type { SkillEntry } from "./mcp-gateway-skills.js"
import type { PluginAccountSource } from "./mcp-plugin-accounts.js"
import { readPluginResource } from "./mcp-plugin-connection.js"
import {
  manifestFile,
  pluginSkill,
  SKILL_DOCUMENT,
  skillInstructions,
  supportingFiles,
  verifiedSkillFile,
  type PluginSkill,
  type VerifiedSkillFile
} from "./mcp-plugin-skill-manifest.js"
import type { UpstreamConnection } from "./mcp-support.js"

export interface PluginSkillReaderDeps {
  readonly accounts: PluginAccountSource | undefined
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
}

export interface PluginSkillReader {
  readonly instructions: (
    server: McpServerRecord,
    skillName: string,
    label: string
  ) => Promise<string | undefined>
  readonly file: (
    server: McpServerRecord,
    skillName: string,
    path: string
  ) => Promise<string | undefined>
}

export const pluginSkillLabel = (pluginName: string, skillName: string): string =>
  `${pluginSlug(pluginName)}:${skillName}`

export const pluginSkillEntries = (
  servers: ReadonlyArray<McpServerRecord>,
  reader: PluginSkillReader
): ReadonlyArray<SkillEntry> => {
  const entries: SkillEntry[] = []
  for (const server of servers) {
    for (const skill of server.capabilities?.skills ?? []) {
      const name = pluginSkillLabel(server.name, skill.name)
      if (entries.some((entry) => entry.name === name)) continue
      entries.push({
        builtin: false,
        name,
        summary: skill.description ?? skill.name,
        ...(skill.description === undefined ? {} : { composer: skill.description }),
        read: () => reader.instructions(server, skill.name, name),
        readFile: (path) => reader.file(server, skill.name, path)
      })
    }
  }
  return entries
}

export const makePluginSkillReader = (deps: PluginSkillReaderDeps): PluginSkillReader => {
  const loadFile = async (server: McpServerRecord, skillName: string, path: string) => {
    const connection = await deps.connectUpstream(server.id)
    const skill = connection.skills.find((candidate) => candidate.name === skillName)
    if (skill === undefined || manifestFile(skill, path) === undefined) return undefined

    const first = await readVerified(server.id, connection, skill, path)
    if (first !== undefined) return { skill, file: first }

    const refreshed = await refreshSkill(connection, skill)
    const second = await readVerified(server.id, connection, refreshed, path)
    if (second !== undefined) return { skill: refreshed, file: second }
    throw new Error(
      `${server.name} served ${path} for ${skillName} that doesn't match its manifest`
    )
  }

  const readVerified = async (
    serverId: string,
    connection: UpstreamConnection,
    skill: PluginSkill,
    path: string
  ): Promise<VerifiedSkillFile | undefined> => {
    const file = manifestFile(skill, path)
    if (file === undefined) return undefined
    const result = await readPluginResource(connection, deps.accounts, serverId, file.uri)
    return verifiedSkillFile(skill, file, result)
  }

  return {
    instructions: async (server, skillName, label) => {
      const loaded = await loadFile(server, skillName, SKILL_DOCUMENT)
      if (loaded === undefined) return undefined
      return instructionsText(server.name, label, loaded.skill, loaded.file)
    },
    file: async (server, skillName, path) => {
      const loaded = await loadFile(server, skillName, path)
      if (loaded === undefined) return undefined
      return fileText(path, loaded.file)
    }
  }
}

const SkillGetSchema = z.looseObject({ skill: z.unknown().optional() })

const pluginSlug = (name: string): string =>
  name
    .toLowerCase()
    .replaceAll(/[^a-z0-9]+/g, "-")
    .replaceAll(/^-+|-+$/g, "") || "plugin"

const refreshSkill = async (
  connection: UpstreamConnection,
  stale: PluginSkill
): Promise<PluginSkill> => {
  const result = await connection.client.request(
    { method: "skills/get", params: { uri: stale.uri } },
    SkillGetSchema
  )
  const fresh = pluginSkill(result.skill) ?? stale
  connection.skills = connection.skills.map((skill) => (skill.uri === stale.uri ? fresh : skill))
  return fresh
}

const instructionsText = (
  pluginName: string,
  label: string,
  skill: PluginSkill,
  file: VerifiedSkillFile
): string => {
  const body = skillInstructions(file.text)
  const files = supportingFiles(skill)
  const origin = `This skill comes from the ${pluginName} plugin.`
  if (files.length === 0) return [body, origin].join("\n\n")
  return [
    body,
    origin,
    `Supporting files (read one by calling this tool with name "${label}" and file set to its path): ${files.join(", ")}`
  ].join("\n\n")
}

const fileText = (path: string, file: VerifiedSkillFile): string => {
  if (!file.binary) return file.text
  return `${path} is a binary file (${file.size} bytes, ${file.mimeType ?? "unknown type"}) that can't be shown here.`
}

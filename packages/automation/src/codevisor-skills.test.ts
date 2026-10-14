import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { codevisorSandboxSignatures } from "./code-executor.js"
import { CODEVISOR_API_TOOLS } from "./codevisor-api-tools.js"
import { makeCodevisorProvider } from "./codevisor-provider.js"

const skillsRoot = join(import.meta.dirname, "..", "resources", "automation-skills")
const codevisorSkills = readdirSync(skillsRoot)
  .filter((name) => name.startsWith("codevisor"))
  .map((name) => ({ name, text: readFileSync(join(skillsRoot, name, "SKILL.md"), "utf8") }))

const sandboxGlobals = ["machines.list", "machines.get", "clients.list"]
const toolNames = new Set([
  ...CODEVISOR_API_TOOLS.map((tool) => tool.name),
  "context.current",
  ...sandboxGlobals
])
const namespaces = new Set([...toolNames].map((name) => name.split(".")[0]))

const referencedTools = (text: string): string[] => {
  const viaTools = [...text.matchAll(/tools\.codevisor\.([a-z_]+\.[a-z_]+)/g)].map((m) => m[1]!)
  const bare = [...text.matchAll(/`([a-z_]+\.[a-z_]+)\(/g)]
    .map((m) => m[1]!)
    .filter((name) => namespaces.has(name.split(".")[0]!))
  return [...viaTools, ...bare]
}

const argumentNames = new Map(
  makeCodevisorProvider(
    () => "http://unused",
    async () => "unused"
  ).tools.map((tool) => [
    tool.name,
    new Set(Object.keys((tool.inputSchema as { properties?: object }).properties ?? {}))
  ])
)

const objectKeys = (text: string, start: number): string[] => {
  const source = text
    .slice(start)
    .replaceAll(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`/g, '""')
    .replaceAll(/\/\/[^\n]*/g, "")
  const segments: string[] = []
  let depth = 0
  let segment = ""
  for (const char of source) {
    if ("{[(".includes(char)) depth += 1
    if ("}])".includes(char)) depth -= 1
    if (depth === 0) break
    if (depth === 1 && char === ",") {
      segments.push(segment)
      segment = ""
    } else if (depth > 1 || char !== "{") segment += depth === 1 ? char : " "
  }
  segments.push(segment)
  return segments.flatMap((part) => {
    const key = part.split(":")[0]!.trim().replace(/\?$/, "")
    return /^[A-Za-z_$][\w$]*$/.test(key) ? [key] : []
  })
}

const toolArguments = (text: string) =>
  [...text.matchAll(/(?:tools\.codevisor\.|`)([a-z_]+\.[a-z_]+)\(\{/g)].flatMap((match) => {
    const tool = match[1]!
    if (!argumentNames.has(tool)) return []
    return [{ tool, keys: objectKeys(text, match.index! + match[0].length - 1) }]
  })

describe("managed Codevisor skills", () => {
  it("ship with frontmatter naming their own directory", () => {
    expect(codevisorSkills.map((skill) => skill.name).toSorted()).toEqual([
      "codevisor",
      "codevisor-agents",
      "codevisor-clients",
      "codevisor-machines"
    ])
    for (const skill of codevisorSkills) {
      expect(skill.text).toMatch(
        new RegExp(`^---\\nname: ${skill.name}\\ndescription: .{80,}\\n---`)
      )
    }
  })

  it("only reference Codevisor tools that exist", () => {
    for (const skill of codevisorSkills) {
      const missing = referencedTools(skill.text).filter((name) => !toolNames.has(name))
      expect({ skill: skill.name, missing }).toEqual({ skill: skill.name, missing: [] })
    }
  })

  it("only pass argument names the tools accept", () => {
    for (const skill of codevisorSkills) {
      const unknown = toolArguments(skill.text).flatMap(({ tool, keys }) =>
        keys.filter((key) => !argumentNames.get(tool)!.has(key)).map((key) => `${tool}: ${key}`)
      )
      expect({ skill: skill.name, unknown }).toEqual({ skill: skill.name, unknown: [] })
    }
  })

  it("only use sandbox globals the execute tool documents", () => {
    for (const declaration of [
      "declare const machines",
      "get(idOrName: string)",
      "declare const clients",
      "declare function status(",
      "declare class MachineUnavailableError",
      "declare class ClientUnavailableError"
    ])
      expect(codevisorSandboxSignatures).toContain(declaration)
  })
})

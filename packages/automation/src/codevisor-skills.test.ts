import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { codevisorSandboxSignatures } from "./code-executor.js"
import { makeCodevisorProvider } from "./codevisor-provider.js"

const skillsRoot = join(import.meta.dirname, "..", "resources", "automation-skills")
const codevisorSkills = readdirSync(skillsRoot)
  .filter((name) => name.startsWith("codevisor"))
  .map((name) => ({ name, text: readFileSync(join(skillsRoot, name, "SKILL.md"), "utf8") }))

const sandboxGlobals = ["machines.list", "machines.get", "clients.list", "agents.get"]
const toolName = "[a-z_]+(?:\\.[a-z_]+)+"
const providerTools = makeCodevisorProvider(
  () => "http://unused",
  async () => "unused"
).tools
const toolNames = new Set([...providerTools.map((tool) => tool.name), ...sandboxGlobals])
const namespaces = new Set([...toolNames].map((name) => name.split(".")[0]))

const globalCall = new RegExp(`(?<![\\w.])(${toolName})\\(`, "g")

const referencedTools = (text: string): string[] =>
  [...text.matchAll(globalCall)]
    .map((m) => m[1]!)
    .filter((name) => namespaces.has(name.split(".")[0]) && !/\.(tools|clients)\./.test(name))

const argumentNames = new Map(
  providerTools.map((tool) => [tool.name, new Set(Object.keys(tool.inputSchema.properties ?? {}))])
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
  [...text.matchAll(new RegExp(`(?<![\\w.])(${toolName})\\(\\{`, "g"))].flatMap((match) => {
    const tool = match[1]!
    if (!argumentNames.has(tool)) return []
    return [{ tool, keys: objectKeys(text, match.index + match[0].length - 1) }]
  })

const acceptsArgument = (tool: string, key: string): boolean =>
  key === "machine" || argumentNames.get(tool)!.has(key)

describe("managed Codevisor skills", () => {
  it("ship with frontmatter naming their own directory", () => {
    expect(codevisorSkills.map((skill) => skill.name).toSorted()).toEqual([
      "codevisor",
      "codevisor-agents",
      "codevisor-clients",
      "codevisor-machines",
      "codevisor-messages"
    ])
    for (const skill of codevisorSkills) {
      expect(skill.text).toMatch(
        new RegExp(`^---\\nname: ${skill.name}\\ndescription: .{80,}\\n---`)
      )
    }
  })

  it("only reference Codevisor tools that exist", () => {
    const agents = codevisorSkills.find((skill) => skill.name === "codevisor-agents")!
    expect(referencedTools(agents.text)).toEqual(
      expect.arrayContaining(["agents.start", "agents.get", "agents.list", "context.current"])
    )
    expect(toolArguments(agents.text).map(({ tool }) => tool)).toEqual(
      expect.arrayContaining(["agents.start", "agents.list", "agents.message"])
    )
    for (const skill of codevisorSkills) {
      const missing = referencedTools(skill.text).filter((name) => !toolNames.has(name))
      expect({ skill: skill.name, missing }).toEqual({ skill: skill.name, missing: [] })
    }
  })

  it("only pass argument names the tools accept", () => {
    for (const skill of codevisorSkills) {
      const unknown = toolArguments(skill.text).flatMap(({ tool, keys }) =>
        keys.filter((key) => !acceptsArgument(tool, key)).map((key) => `${tool}: ${key}`)
      )
      expect({ skill: skill.name, unknown }).toEqual({ skill: skill.name, unknown: [] })
    }
  })

  it("only use sandbox globals the execute tool documents", () => {
    for (const declaration of [
      "declare const machines",
      "get(idOrName: string)",
      "list(): Promise<{ items: Machine[] }>",
      "declare const agents: {",
      "clients: { list(): Promise<{ items: Client[] }> }",
      "declare function status(",
      "declare class MachineUnavailableError",
      "declare class ClientUnavailableError"
    ])
      expect(codevisorSandboxSignatures).toContain(declaration)
  })
})

import { join } from "node:path"

import { textToolResult, type AutomationToolProvider } from "@codevisor/automation"
import { browserUseTools, type BrowserUseProvider } from "@codevisor/automation"
import { computerUseTools } from "@codevisor/automation"
import { requireServerResource, type ServerResourceOptions } from "@codevisor/automation"

import { packagedSkill, type BuiltinSkill } from "./mcp-gateway-skills.js"
import { errorMessage } from "./mcp-support.js"

export const BUILTIN_MCP_SERVERS = [
  { id: "browser", name: "Browser Use", kind: "browserUse" as const },
  { id: "computer", name: "Computer Use", kind: "computerUse" as const },
  { id: "codevisor", name: "Codevisor", kind: "codevisor" as const }
] as const

export type BuiltinMcpId = (typeof BUILTIN_MCP_SERVERS)[number]["id"]

export const isBuiltinMcpId = (id: string): id is BuiltinMcpId =>
  BUILTIN_MCP_SERVERS.some((builtin) => builtin.id === id)

const AUTOMATION_SKILLS = [
  {
    gate: "browser",
    name: "browser-use",
    summary:
      "Use when a task involves a website or browser tab: opening, reading, clicking, typing, or testing",
    composer: "Browse the web with Codevisor's browser"
  },
  {
    gate: "computer",
    name: "computer-use",
    summary:
      "Use when a desktop app must be operated or the screen recorded, such as a video of a fix",
    composer: "Operate desktop apps and record the screen"
  },
  {
    gate: "codevisor",
    name: "codevisor",
    summary: "Use when work needs other agents, workspaces, another machine, or the Codevisor app"
  },
  {
    gate: "codevisor",
    name: "codevisor-agents",
    summary:
      "Use when you want a helper agent, an agent per issue or PR, or to manage other agents",
    composer: "Start and coordinate other agents in Codevisor"
  },
  {
    gate: "codevisor",
    name: "codevisor-machines",
    summary: "Use when work involves another of the user's machines, a new server, or a sandbox"
  },
  {
    gate: "codevisor",
    name: "codevisor-clients",
    summary:
      "Use when the user wants something shown, opened, or laid out in their Codevisor window"
  },
  {
    gate: "bot",
    name: "codevisor-messages",
    summary:
      "Use when you are a Codevisor bot, before replying to the user or when a codevisor-event arrives"
  }
] as const satisfies ReadonlyArray<{
  gate: BuiltinMcpId | "bot"
  name: string
  summary: string
  composer?: string
}>

export type AutomationSkillName = (typeof AUTOMATION_SKILLS)[number]["name"]

export const automationSkillPath = (
  id: "browser" | "computer",
  options: ServerResourceOptions = {}
): string => managedSkillPath(id === "browser" ? "browser-use" : "computer-use", options)

export const managedSkillPath = (
  skillName: AutomationSkillName,
  options: ServerResourceOptions = {}
): string => {
  const relative = join("automation-skills", skillName, "SKILL.md")
  return requireServerResource(relative, `${skillName} skill`, options)
}

export const automationSkills = (
  options: ServerResourceOptions = {}
): ReadonlyArray<BuiltinSkill> =>
  AUTOMATION_SKILLS.map((skill) =>
    packagedSkill(
      {
        name: skill.name,
        path: () => managedSkillPath(skill.name, options),
        summary: skill.summary,
        ...("composer" in skill ? { composer: skill.composer } : {})
      },
      skill.gate
    )
  )

export const unavailableBrowserProvider = (cause: unknown): BrowserUseProvider => {
  const detail = errorMessage(cause)
  const unavailable = (): never => {
    throw new Error(detail)
  }
  return {
    id: "browser",
    tools: browserUseTools,
    ensureSetup: async () => unavailable(),
    status: () => ({
      backend: "missing",
      error: detail,
      extensionConnected: false,
      chromeAvailable: false,
      extensionSetupMode: "development"
    }),
    sessionBackend: () => undefined,
    setSessionBackend: () => undefined,
    beginTurn: async () => undefined,
    acceptBrowserHost: (socket) => {
      socket.close(1011, detail)
    },
    acceptExtensionConnection: (socket) => {
      socket.close()
    },
    acceptNativeHostConnection: (socket) => {
      socket.close()
    },
    onExtensionConnectionChange: () => () => undefined,
    openDevelopmentExtensionFolder: unavailable,
    openDevelopmentExtensionPage: unavailable,
    openDevelopmentExtensionInstaller: unavailable,
    openExtensionWebStore: unavailable,
    extensionArchivePath: unavailable,
    extensionIconPath: unavailable,
    configureExtensionRelay: () => undefined,
    invoke: async () => textToolResult(detail, true),
    closeSession: async () => undefined,
    close: async () => undefined
  }
}

export const unavailableComputerProvider = (
  cause: unknown
): AutomationToolProvider & {
  readonly ensureSetup: () => Promise<void>
  readonly status: () => Readonly<Record<string, unknown>>
} => {
  const detail = errorMessage(cause)
  return {
    id: "computer",
    tools: computerUseTools,
    ensureSetup: async () => {
      throw new Error(detail)
    },
    status: () => ({ platform: process.platform, available: false, detail }),
    invoke: async () => textToolResult(detail, true),
    closeSession: async () => undefined,
    close: async () => undefined
  }
}

export const initializeAutomationProvider = <A>(
  name: string,
  initialize: () => A,
  unavailable: (cause: unknown) => A
): A => {
  try {
    return initialize()
  } catch (cause) {
    console.error(`${name} unavailable: ${errorMessage(cause)}`)
    return unavailable(cause)
  }
}

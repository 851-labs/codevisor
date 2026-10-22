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
    summary: "drive a real web browser: open sites, sign in, click, type, read live pages",
    composer: "Browse the web with Codevisor's browser"
  },
  {
    gate: "computer",
    name: "computer-use",
    summary: "see and operate desktop apps, and record the screen",
    composer: "Operate desktop apps and record the screen"
  },
  {
    gate: "codevisor",
    name: "codevisor",
    summary: "map of Codevisor: other agents, workspaces, machines, and the app"
  },
  {
    gate: "codevisor",
    name: "codevisor-agents",
    summary: "start and coordinate other agents as visible Codevisor chats",
    composer: "Start and coordinate other agents in Codevisor"
  },
  {
    gate: "codevisor",
    name: "codevisor-machines",
    summary: "run tools or agents on the user's other machines"
  },
  {
    gate: "codevisor",
    name: "codevisor-clients",
    summary: "see and drive the user's open Codevisor windows"
  },
  {
    gate: "bot",
    name: "codevisor-messages",
    summary: "how a bot talks to the user: messages.send is the only output they see"
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
      extensionNeedsUpdate: false,
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

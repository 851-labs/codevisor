import { textToolResult, type AutomationToolProvider } from "@codevisor/automation"
import { browserUseTools, type BrowserUseProvider } from "@codevisor/automation"
import { computerUseTools } from "@codevisor/automation"
import { requireServerResource, type ServerResourceOptions } from "@codevisor/automation"
import type { ManagedSkillSpec } from "@codevisor/skills"
import { dirname, join } from "node:path"
import { errorMessage } from "./mcp-support.js"

export const BUILTIN_MCP_SERVERS = [
  { id: "browser", name: "Browser Use", kind: "browserUse" as const },
  { id: "computer", name: "Computer Use", kind: "computerUse" as const }
] as const

export const automationSkillPath = (
  id: "browser" | "computer",
  options: ServerResourceOptions = {}
): string => {
  const skillName = id === "browser" ? "browser-use" : "computer-use"
  const relative = join("automation-skills", skillName, "SKILL.md")
  return requireServerResource(relative, `managed ${skillName} skill`, options)
}

export const managedAutomationSkills = (
  enabledIds: ReadonlySet<string>
): ReadonlyArray<ManagedSkillSpec> =>
  (["browser", "computer"] as const).map((id) => {
    const enabled = enabledIds.has(id)
    return {
      directoryName: id === "browser" ? "browser-use" : "computer-use",
      enabled,
      // Disabled managed skills only need their installed copies removed.
      // Do not make an absent optional resource block that cleanup.
      sourcePath: enabled ? dirname(automationSkillPath(id)) : ""
    }
  })

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
    acceptExtensionConnection: (socket) => {
      socket.close()
    },
    waitForExtensionConnection: async () => unavailable(),
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

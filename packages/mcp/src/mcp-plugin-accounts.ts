import type { Tool } from "@modelcontextprotocol/sdk/types.js"

import { isNonArrayRecord } from "./mcp-guards.js"

export const ACCOUNT_META_KEY = "dev.codevisor/account"

export const ACCOUNT_ARGUMENT = "account"

export interface PluginAccountChoice {
  readonly id: string
  readonly label: string
}

export interface PluginAccountSource {
  readonly list: (serverId: string) => Promise<ReadonlyArray<PluginAccountChoice>>
  readonly meta: (
    serverId: string,
    accountId?: string
  ) => Promise<Record<string, unknown> | undefined>
}

export interface PluginServerName {
  readonly id: string
  readonly name: string
}

export interface PluginToolCall {
  readonly arguments: Record<string, unknown>
  readonly accountId?: string
  readonly meta?: Record<string, unknown>
}

export const accountChoices = async (
  accounts: PluginAccountSource | undefined,
  serverId: string
): Promise<ReadonlyArray<PluginAccountChoice>> => {
  if (accounts === undefined) return []
  return accounts.list(serverId)
}

export const accountMeta = async (
  accounts: PluginAccountSource | undefined,
  serverId: string,
  accountId?: string
): Promise<Record<string, unknown> | undefined> => {
  const chosen = accountId ?? (await accountChoices(accounts, serverId))[0]?.id
  if (accounts === undefined || chosen === undefined) return undefined

  const context = await accounts.meta(serverId, chosen)
  if (context === undefined) return undefined
  return { [ACCOUNT_META_KEY]: context }
}

export const withMeta = (
  params: Record<string, unknown>,
  meta: Record<string, unknown> | undefined
): Record<string, unknown> => {
  if (meta === undefined) return params
  const existing = isNonArrayRecord(params._meta) ? params._meta : {}
  return { ...params, _meta: { ...existing, ...meta } }
}

export const withAccountArguments = async (
  accounts: PluginAccountSource | undefined,
  server: PluginServerName,
  tools: ReadonlyArray<Tool>
): Promise<ReadonlyArray<Tool>> => {
  const choices = await accountChoices(accounts, server.id)
  if (choices.length < 2) return tools
  return tools.map((tool) => withAccountArgument(tool, server.name, choices))
}

export const pluginToolCall = async (
  accounts: PluginAccountSource | undefined,
  server: PluginServerName,
  tool: Tool | undefined,
  input: Record<string, unknown>
): Promise<PluginToolCall> => {
  const choices = await accountChoices(accounts, server.id)
  const offered = tool !== undefined && offersAccountArgument(tool, choices)
  const { [ACCOUNT_ARGUMENT]: label, ...rest } = input
  const forwarded = offered ? rest : input

  const accountId = chosenAccountId(server.name, choices, offered ? label : undefined)
  const meta = await accountMeta(accounts, server.id, accountId)
  return {
    arguments: forwarded,
    ...(accountId === undefined ? {} : { accountId }),
    ...(meta === undefined ? {} : { meta })
  }
}

const offersAccountArgument = (tool: Tool, choices: ReadonlyArray<PluginAccountChoice>): boolean =>
  choices.length > 1 && !(ACCOUNT_ARGUMENT in (tool.inputSchema.properties ?? {}))

const withAccountArgument = (
  tool: Tool,
  pluginName: string,
  choices: ReadonlyArray<PluginAccountChoice>
): Tool => {
  if (!offersAccountArgument(tool, choices)) return tool
  return {
    ...tool,
    inputSchema: {
      ...tool.inputSchema,
      properties: {
        ...tool.inputSchema.properties,
        [ACCOUNT_ARGUMENT]: {
          type: "string",
          enum: choices.map((choice) => choice.label),
          description: `Which ${pluginName} account; defaults to the first`
        }
      }
    }
  }
}

const chosenAccountId = (
  pluginName: string,
  choices: ReadonlyArray<PluginAccountChoice>,
  label: unknown
): string | undefined => {
  if (label === undefined) return choices[0]?.id

  const chosen = choices.find((choice) => choice.label === label)
  if (chosen !== undefined) return chosen.id
  const labels = choices.map((choice) => `"${choice.label}"`).join(", ")
  throw new Error(`Unknown ${pluginName} account ${JSON.stringify(label)}; use one of ${labels}`)
}

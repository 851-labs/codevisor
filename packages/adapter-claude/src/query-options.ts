import type { Options as ClaudeOptions } from "@anthropic-ai/claude-agent-sdk"
import type { ToolGatewayConfig } from "@codevisor/agent-runtime"

import { claudeSessionHooks } from "./session-hooks.js"
import type { CurrentSession } from "./session.js"
import { claudeToolPermission } from "./tool-permission.js"

export interface QueryLaunch {
  readonly abort: AbortController
  readonly claudePath: string
  readonly currentSession: CurrentSession
  readonly cwd: string
  readonly env: Record<string, string>
  readonly resume: string | undefined
  readonly sessionKey: string
  readonly startOptions: Pick<ClaudeOptions, "model" | "settings">
  readonly toolGateway: ToolGatewayConfig | undefined
}

export const claudeQueryOptions = (launch: QueryLaunch): ClaudeOptions => ({
  ...launch.startOptions,
  abortController: launch.abort,
  cwd: launch.cwd,
  env: launch.env,
  includePartialMessages: true,
  pathToClaudeCodeExecutable: launch.claudePath,
  systemPrompt: { type: "preset", preset: "claude_code" },
  ...gatewayMcpOptions(launch.toolGateway),
  canUseTool: claudeToolPermission(launch.currentSession),
  permissionMode: "bypassPermissions",
  allowDangerouslySkipPermissions: true,
  hooks: claudeSessionHooks(launch.currentSession),
  ...sessionArgs(launch)
})

const gatewayMcpOptions = (
  toolGateway: ToolGatewayConfig | undefined
): Pick<ClaudeOptions, "mcpServers" | "strictMcpConfig"> => {
  if (toolGateway === undefined) return {}

  return {
    strictMcpConfig: true,
    mcpServers: {
      [toolGateway.name]: {
        type: "http",
        url: toolGateway.url,
        headers: { Authorization: `Bearer ${toolGateway.bearerToken}` }
      }
    }
  }
}

const sessionArgs = (launch: QueryLaunch): Pick<ClaudeOptions, "extraArgs" | "resume"> => {
  const nativeToolArgs = nativeToolArgsFor(launch.toolGateway)
  if (launch.resume === undefined) {
    return { extraArgs: { ...nativeToolArgs, "session-id": launch.sessionKey } }
  }
  if (launch.toolGateway === undefined) return { resume: launch.resume }

  return { extraArgs: nativeToolArgs, resume: launch.resume }
}

const nativeToolArgsFor = (
  toolGateway: ToolGatewayConfig | undefined
): Record<string, string | null> => (toolGateway === undefined ? {} : { "no-chrome": null })

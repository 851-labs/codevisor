import type { HarnessAccountContext } from "@codevisor/agent-runtime"

const CLAUDE_AUTH_OVERRIDE_ENV_VARS = [
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
  "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
] as const

export const claudeAccountEnv = (
  baseEnv: NodeJS.ProcessEnv,
  account: HarnessAccountContext | undefined
): Record<string, string> => {
  const env = definedEnv(baseEnv)
  if (account?.profileKind === "managed") dropAuthOverrides(env)
  for (const name of account?.unsetEnv ?? []) delete env[name]
  Object.assign(env, account?.env)
  return env
}

const definedEnv = (env: NodeJS.ProcessEnv): Record<string, string> =>
  Object.fromEntries(
    Object.entries(env).filter((entry): entry is [string, string] => typeof entry[1] === "string")
  )

const dropAuthOverrides = (env: Record<string, string>): void => {
  for (const name of CLAUDE_AUTH_OVERRIDE_ENV_VARS) delete env[name]
}

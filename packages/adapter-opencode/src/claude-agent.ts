import { SEEDED_CREDENTIAL_PREFIX, type SeededOpenCodeCredential } from "./accounts.js"
import { CLAUDE_AGENT_METHOD, CLAUDE_AGENT_PROVIDER } from "./integrations.js"

export const CLAUDE_AGENT_ACCOUNT_PROMPT = "account"

export const claudeAgentCredential: SeededOpenCodeCredential = {
  id: `${SEEDED_CREDENTIAL_PREFIX}${CLAUDE_AGENT_PROVIDER}`,
  integrationID: CLAUDE_AGENT_PROVIDER,
  value: { type: "external", methodID: CLAUDE_AGENT_METHOD }
}

export interface ClaudeAgentLaunch {
  readonly claudePath: string
  readonly env: Readonly<Record<string, string>>
}

const PASSED_ENV = [
  "CLAUDE_CONFIG_DIR",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_BASE_URL"
] as const

const OVERRIDING_ENV = [
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
  "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
] as const

const ENV_PREFIX = "CODEVISOR_CLAUDE_AGENT_"
const CLAUDE_PATH_ENV = `${ENV_PREFIX}PATH`

const isolated = `"\${${ENV_PREFIX}CLAUDE_CONFIG_DIR+set}"`

export const claudeAgentLauncher = [
  "#!/bin/sh",
  `if [ -n ${isolated} ]; then unset ${OVERRIDING_ENV.join(" ")}; fi`,
  ...PASSED_ENV.map(
    (name) =>
      `if [ -n "\${${ENV_PREFIX}${name}+set}" ]; then export ${name}="$${ENV_PREFIX}${name}"; unset ${ENV_PREFIX}${name}; fi`
  ),
  `claude="$${CLAUDE_PATH_ENV}"`,
  `unset ${CLAUDE_PATH_ENV}`,
  'exec "$claude" "$@"',
  ""
].join("\n")

export const claudeAgentEnv = (
  launcherPath: string,
  launch: ClaudeAgentLaunch
): Record<string, string> => ({
  OPENCODE_CLAUDE_PATH: launcherPath,
  [CLAUDE_PATH_ENV]: launch.claudePath,
  ...Object.fromEntries(
    PASSED_ENV.flatMap((name) => {
      const value = launch.env[name]
      return value === undefined ? [] : [[`${ENV_PREFIX}${name}`, value]]
    })
  )
})

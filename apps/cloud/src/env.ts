export interface CloudEnv extends Omit<Env, "APPLE_NATIVE_CLIENT_ID" | "RELAY_MAP"> {
  BETTER_AUTH_SECRET?: string
  GITHUB_CLIENT_ID?: string
  GITHUB_CLIENT_SECRET?: string
  MCP_GITHUB_CLIENT_ID?: string
  MCP_GITHUB_CLIENT_SECRET?: string
  OAUTH_CLIENT_FETCH?: (input: string, init?: RequestInit) => Promise<Response>
  APPLE_CLIENT_ID?: string
  APPLE_NATIVE_CLIENT_ID?: string
  APPLE_TEAM_ID?: string
  APPLE_KEY_ID?: string
  APPLE_PRIVATE_KEY?: string
  RESEND_API_KEY?: string
  AUTH_EMAIL_FROM?: string
  AUTH_EMAIL_FETCH?: (input: string, init?: RequestInit) => Promise<Response>
  PLUGIN_REPORT_SLACK_WEBHOOK?: string
  PLUGIN_REPORT_FETCH?: (input: string, init?: RequestInit) => Promise<Response>
  DEV_AUTH?: string
  HOOKS_BASE_URL?: string
  RESUME_GRACE_MS?: string
  RELAY_MAP?: string
  RELAY_AUTHORIZE_TOKEN?: string
}

export const isDevAuthEnabled = (env: CloudEnv): boolean => env.DEV_AUTH === "1"

export const DEV_USER = {
  email: "dev@codevisor.local",
  password: "codevisor-dev-password",
  name: "Dev User"
} as const

/// Worker environment: generated bindings/vars (worker-configuration.d.ts)
/// plus values wrangler cannot know about — deploy-time secrets and the
/// dev-only vars injected by `wrangler dev --var` (see scripts/dev.mjs).
export interface CloudEnv extends Omit<Env, "APPLE_NATIVE_CLIENT_ID"> {
  /// ≥32 chars; `openssl rand -base64 32`. Required outside dev auth mode.
  BETTER_AUTH_SECRET?: string
  GITHUB_CLIENT_ID?: string
  GITHUB_CLIENT_SECRET?: string
  APPLE_CLIENT_ID?: string
  APPLE_NATIVE_CLIENT_ID?: string
  APPLE_TEAM_ID?: string
  APPLE_KEY_ID?: string
  /// PKCS#8 .p8 key stored only as a Worker secret.
  APPLE_PRIVATE_KEY?: string
  RESEND_API_KEY?: string
  AUTH_EMAIL_FROM?: string
  /** Test seam for transactional mail; never configured in production. */
  AUTH_EMAIL_FETCH?: (input: string, init?: RequestInit) => Promise<Response>
  /// GitHub API token for the plugin-index poller (public-repo read access is
  /// enough). Optional: without it the search runs unauthenticated and hits
  /// GitHub's much lower anonymous rate limit.
  GITHUB_TOKEN?: string
  /// Bearer token authorizing POST /plugins/refresh on deployed instances.
  /// Absent (and outside dev auth) the route does not exist.
  PLUGINS_REFRESH_TOKEN?: string
  PLUGIN_REPORT_SLACK_WEBHOOK?: string
  /** Test seam for report notifications; never configured in production. */
  PLUGIN_REPORT_FETCH?: (input: string, init?: RequestInit) => Promise<Response>
  /// Test seam: fetch used for all GitHub traffic by the plugin indexer, so
  /// tests never touch the network. Never set on a deployed instance.
  GITHUB_FETCH?: (input: string, init?: RequestInit) => Promise<Response>
  /// "1" only on local dev instances; never present in deployed config.
  DEV_AUTH?: string
  /// Test seam: overrides the session-resume grace window (ms). Production
  /// uses the default in resume-sessions.ts.
  RESUME_GRACE_MS?: string
}

export const isDevAuthEnabled = (env: CloudEnv): boolean => env.DEV_AUTH === "1"

/// Fixed identity for the dev-only credential login. Public by design: it can
/// only ever exist on instances that explicitly opted into DEV_AUTH.
export const DEV_USER = {
  email: "dev@codevisor.local",
  password: "codevisor-dev-password",
  name: "Dev User"
} as const

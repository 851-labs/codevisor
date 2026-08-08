/// Worker environment: generated bindings/vars (worker-configuration.d.ts)
/// plus values wrangler cannot know about — deploy-time secrets and the
/// dev-only vars injected by `wrangler dev --var` (see scripts/dev.mjs).
export interface CloudEnv extends Env {
  /// ≥32 chars; `openssl rand -base64 32`. Required outside dev auth mode.
  BETTER_AUTH_SECRET?: string
  GITHUB_CLIENT_ID?: string
  GITHUB_CLIENT_SECRET?: string
  /// "1" only on local dev instances; never present in deployed config.
  DEV_AUTH?: string
}

export const isDevAuthEnabled = (env: CloudEnv): boolean => env.DEV_AUTH === "1"

/// Fixed identity for the dev-only credential login. Public by design: it can
/// only ever exist on instances that explicitly opted into DEV_AUTH.
export const DEV_USER = {
  email: "dev@codevisor.local",
  password: "codevisor-dev-password",
  name: "Dev User"
} as const

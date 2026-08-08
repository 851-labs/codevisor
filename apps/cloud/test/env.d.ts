import type { D1Migration } from "@cloudflare/vitest-pool-workers"

/// Test-only additions to the Worker env: the migrations blob injected via
/// vitest.config.ts, plus the secrets wrangler types can't know about.
declare global {
  namespace Cloudflare {
    interface Env {
      TEST_MIGRATIONS: D1Migration[]
      BETTER_AUTH_SECRET?: string
      GITHUB_CLIENT_ID?: string
      GITHUB_CLIENT_SECRET?: string
      /// Injected via vitest.config.ts miniflare bindings (not wrangler.jsonc).
      DEV_AUTH?: string
    }
  }
}

export {}

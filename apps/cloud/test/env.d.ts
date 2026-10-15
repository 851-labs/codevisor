import type { D1Migration } from "@cloudflare/vitest-plugin"

declare global {
  namespace Cloudflare {
    interface Env {
      TEST_MIGRATIONS: D1Migration[]
      BETTER_AUTH_SECRET?: string
      GITHUB_CLIENT_ID?: string
      GITHUB_CLIENT_SECRET?: string
      DEV_AUTH?: string
    }
  }
}

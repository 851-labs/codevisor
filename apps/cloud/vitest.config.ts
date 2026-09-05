import path from "node:path"
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers"
import { defineConfig } from "vitest/config"

export default defineConfig(async () => {
  // D1 migrations are applied per-test-run by test/apply-migrations.ts.
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "drizzle"))
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // The checked-in wrangler.jsonc carries production values; tests
            // run as a dev-auth instance.
            DEV_AUTH: "1",
            PUBLIC_BASE_URL: "http://localhost:8787",
            INSTANCE_NAME: "Codevisor Cloud (test)"
          }
        }
      })
    ],
    test: {
      include: ["test/**/*.test.ts"],
      setupFiles: ["./test/apply-migrations.ts"]
    }
  }
})

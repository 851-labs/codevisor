import path from "node:path"

import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers"
import { defineConfig } from "vitest/config"

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "drizzle"))
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            DEV_AUTH: "1",
            RESEND_API_KEY: "",
            PUBLIC_BASE_URL: "http://localhost:8787",
            INSTANCE_NAME: "Codevisor Cloud (test)",
            RELAY_MAP: JSON.stringify([
              { url: "https://relay-test.codevisor.dev", quicPort: 7842 }
            ]),
            RELAY_AUTHORIZE_TOKEN: "relay-secret, relay-next"
          }
        }
      })
    ],
    environments: {
      ssr: { resolve: { conditions: ["@codevisor/source"] } }
    },
    test: {
      include: ["test/**/*.test.ts"],
      setupFiles: ["./test/apply-migrations.ts"]
    }
  }
})

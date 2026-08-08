import { defineConfig } from "drizzle-kit"

/// SQL migrations land in ./drizzle (wrangler.jsonc `migrations_dir`) and are
/// applied with `wrangler d1 migrations apply` — locally on dev boot, remotely
/// by CI before deploy.
export default defineConfig({
  dialect: "sqlite",
  schema: "./src/db/schema.ts",
  out: "./drizzle"
})

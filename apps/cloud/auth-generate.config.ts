/// Generator-only Better Auth config: `bun run db:schema` points the CLI here
/// to emit src/db/schema.ts. It must mirror the plugin list in src/auth.ts
/// (that's what determines the tables) but must not import the generated
/// schema itself. Never imported by Worker code.
import { apiKey } from "@better-auth/api-key"
import { drizzleAdapter } from "@better-auth/drizzle-adapter"
import { betterAuth } from "better-auth"
import { bearer, deviceAuthorization } from "better-auth/plugins"
import { oneTimeToken } from "better-auth/plugins/one-time-token"
import { drizzle } from "drizzle-orm/d1"

export const auth = betterAuth({
  baseURL: "http://localhost:8787",
  secret: "generator-only-secret-never-used",
  database: drizzleAdapter(drizzle({} as never), { provider: "sqlite" }),
  emailAndPassword: { enabled: true },
  socialProviders: {
    github: { clientId: "generator", clientSecret: "generator" }
  },
  plugins: [
    bearer(),
    oneTimeToken(),
    deviceAuthorization({ verificationUri: "/device" }),
    apiKey({ enableMetadata: true })
  ]
})

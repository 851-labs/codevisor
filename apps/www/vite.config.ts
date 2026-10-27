import { cloudflare } from "@cloudflare/vite-plugin"
import tailwindcss from "@tailwindcss/vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import mdx from "fumadocs-mdx/vite"
import { defaultClientConditions, defineConfig } from "vite"

import { GITHUB_REPO_API_URL, githubRequestHeaders, parseStars } from "./src/lib/github-repo"

const STARS_AT_BUILD_TIMEOUT_MS = 10_000

const starsAtBuild = async (command: string): Promise<number | null> => {
  if (command !== "build") return null

  const response = await fetch(GITHUB_REPO_API_URL, {
    headers: githubRequestHeaders(process.env.GITHUB_TOKEN),
    signal: AbortSignal.timeout(STARS_AT_BUILD_TIMEOUT_MS)
  }).catch(() => undefined)
  const stars = parseStars(await response?.json().catch(() => null))
  if (stars === null) console.warn(`GitHub stars unavailable at build time (${response?.status})`)
  return stars
}

export default defineConfig(async ({ command }) => ({
  define: {
    "import.meta.env.GITHUB_STARS_AT_BUILD": JSON.stringify(await starsAtBuild(command))
  },
  plugins: [
    cloudflare({ viteEnvironment: { name: "ssr" } }),
    mdx(),
    tanstackStart(),
    viteReact(),
    tailwindcss()
  ],
  resolve: {
    conditions: ["@codevisor/source", ...defaultClientConditions]
  },
  environments: {
    ssr: { resolve: { conditions: ["@codevisor/source"] } }
  },
  ssr: {
    noExternal: ["fumadocs-core", "fumadocs-ui", "fumadocs-openapi", "@fumadocs/base-ui"]
  }
}))

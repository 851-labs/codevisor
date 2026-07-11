import { cloudflare } from "@cloudflare/vite-plugin"
import tailwindcss from "@tailwindcss/vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import mdx from "fumadocs-mdx/vite"
import { fileURLToPath } from "node:url"
import { defineConfig } from "vite"

export default defineConfig({
  plugins: [
    cloudflare({ viteEnvironment: { name: "ssr" } }),
    mdx(),
    tanstackStart(),
    viteReact(),
    tailwindcss()
  ],
  resolve: {
    alias: {
      "@herdman/api": fileURLToPath(new URL("../../packages/api/src/index.ts", import.meta.url))
    }
  },
  ssr: {
    noExternal: ["fumadocs-core", "fumadocs-ui", "fumadocs-openapi", "@fumadocs/base-ui"]
  }
})

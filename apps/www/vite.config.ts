import { cloudflare } from "@cloudflare/vite-plugin"
import tailwindcss from "@tailwindcss/vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import mdx from "fumadocs-mdx/vite"
import { defaultClientConditions, defineConfig } from "vite"

export default defineConfig({
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
})

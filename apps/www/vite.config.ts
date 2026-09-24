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
  // Workspace packages export their TypeScript source under the
  // "@codevisor/source" condition (see packages/api/package.json), so the site
  // bundles @codevisor/api from src without a build step or a path alias.
  resolve: {
    conditions: ["@codevisor/source", ...defaultClientConditions]
  },
  // The Worker environment keeps the Cloudflare plugin's workerd conditions;
  // Vite appends this one to them.
  environments: {
    ssr: { resolve: { conditions: ["@codevisor/source"] } }
  },
  ssr: {
    noExternal: ["fumadocs-core", "fumadocs-ui", "fumadocs-openapi", "@fumadocs/base-ui"]
  }
})

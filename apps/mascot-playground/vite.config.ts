import viteReact from "@vitejs/plugin-react"
import { defaultClientConditions, defaultServerConditions, defineConfig } from "vite"

const sourceCondition = "@codevisor/source"

export default defineConfig({
  plugins: [viteReact()],
  resolve: {
    conditions: [sourceCondition, ...defaultClientConditions]
  },
  ssr: {
    resolve: {
      conditions: [sourceCondition, ...defaultServerConditions]
    }
  }
})

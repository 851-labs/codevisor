import tailwindcss from "@tailwindcss/vite"
import { tanstackRouter } from "@tanstack/router-plugin/vite"
import viteReact from "@vitejs/plugin-react"
import { defineConfig } from "vite"

// The desktop app (apps/desktop) loads this SPA in its webview: `tauri dev`
// points at this dev server, production loads the built dist/ from disk.
// The /v1 proxy makes browser-only development same-origin with the herdman
// dev server so no CORS or auth token is involved (loopback is auth-exempt).
export default defineConfig({
  plugins: [tanstackRouter({ target: "react" }), viteReact(), tailwindcss()],
  clearScreen: false,
  server: {
    port: 3001,
    strictPort: true,
    proxy: {
      "/v1": {
        target: process.env.HERDMAN_DEV_SERVER_URL ?? "http://127.0.0.1:49362",
        ws: true
      }
    }
  }
})

import { defineTestConfig } from "@codevisor/vitest-config"

export default defineTestConfig({
  test: { coverage: { provider: "v8", reporter: ["text", "json"] } }
})

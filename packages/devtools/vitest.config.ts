import { defineTestConfig } from "@codevisor/vitest-config"

export default defineTestConfig({
  test: {
    coverage: {
      include: ["src/**/*.ts"],
      exclude: [
        "**/*.test.ts",
        "src/ship.ts",
        "src/dev-net.ts",
        "src/dev-relays.ts",
        "src/dev-relay-certificates.ts"
      ],
      provider: "v8",
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})

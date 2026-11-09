import { defineTestConfig } from "@codevisor/vitest-config"

const macOSOnly =
  process.platform === "darwin" ? [] : ["src/apfs-clone.ts", "src/swift-artifacts.ts"]

export default defineTestConfig({
  test: {
    coverage: {
      include: ["src/**/*.ts"],
      exclude: [
        "**/*.test.ts",
        "src/ship.ts",
        "src/dev-net.ts",
        "src/dev-relays.ts",
        "src/dev-relay-certificates.ts",
        "src/ios-simulator-owner.ts",
        "src/dev-owner.ts",
        "src/dev-worker.ts",
        "src/dev-ios-worker.ts",
        "src/xcode-window.ts",
        ...macOSOnly
      ],
      provider: "v8",
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 }
    }
  }
})

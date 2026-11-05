import { beforeEach, vi } from "vitest"

beforeEach(() => {
  vi.stubEnv("GIT_CONFIG_GLOBAL", "/dev/null")
  vi.stubEnv("GIT_CONFIG_SYSTEM", "/dev/null")
  vi.stubEnv("GIT_CONFIG_NOSYSTEM", "1")
  vi.stubEnv("GIT_CONFIG_COUNT", "0")
  vi.stubEnv("GIT_TERMINAL_PROMPT", "0")
})

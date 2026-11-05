import { mergeConfig, type ViteUserConfig } from "vitest/config"

export const defineTestConfig = (config: ViteUserConfig): ViteUserConfig =>
  mergeConfig(config, { test: testStateResets })

const testStateResets = { restoreMocks: true, unstubEnvs: true, unstubGlobals: true }

import {
  configDefaults,
  mergeConfig,
  type TestProjectInlineConfiguration,
  type ViteUserConfig
} from "vitest/config"

const isolatedTestSuffix = ".isolated.test.ts"

export const defineTestConfig = (config: ViteUserConfig): ViteUserConfig => {
  const { include = defaultInclude, ...test } = config.test ?? {}
  return mergeConfig(
    { ...config, test },
    {
      test: {
        ...testStateResets,
        ...ciReporters(),
        sequence: { shuffle: true },
        projects: [sharedModuleTests(include), isolatedModuleTests(include)]
      }
    }
  )
}

const defaultInclude = ["**/*.test.ts"]
const junitReport = "tmp/junit.xml"

const ciReporters = (): Pick<NonNullable<ViteUserConfig["test"]>, "reporters"> => {
  if (process.env.GITHUB_ACTIONS !== "true") return {}

  return { reporters: ["default", "github-actions", ["junit", { outputFile: junitReport }]] }
}
const testStateResets = { restoreMocks: true, unstubEnvs: true, unstubGlobals: true }

const sharedModuleTests = (include: Array<string>): TestProjectInlineConfiguration => ({
  extends: true,
  test: {
    name: "shared",
    include,
    exclude: [...configDefaults.exclude, `**/*${isolatedTestSuffix}`],
    isolate: false
  }
})

const isolatedModuleTests = (include: Array<string>): TestProjectInlineConfiguration => ({
  extends: true,
  test: { name: "isolated", include: include.map(isolatedPattern) }
})

const isolatedPattern = (pattern: string): string =>
  pattern.replace(/\.test\.ts$/, isolatedTestSuffix)

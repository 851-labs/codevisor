const toolingInputs = [
  "package.json",
  "bun.lock",
  "lefthook.yml",
  "scripts/check.mjs",
  "scripts/check-plan.mjs"
]
const javascriptInputs = [
  ".node-version",
  "tsconfig.base.json",
  "tsconfig.json",
  "turbo.json",
  "vitest.config.ts"
]
const nativeInputs = [
  "packages/net/**",
  "scripts/net-build.lock.json",
  "scripts/build-net-swift.sh"
]

const alwaysStep = (name) => ({
  name,
  lane: "javascript",
  always: true,
  command: () => ["bun", "run", name]
})

const turboStep = (name) => ({
  name,
  lane: "javascript",
  command: (filters) => ["bun", "run", name, ...filters],
  select: ({ files, context }) => {
    const shared = files.filter((file) => matchesAny(file, javascriptInputs))
    if (shared.length > 0) return { inputs: files, args: [], reason: shared[0] }
    const names = new Set()
    const inputs = files.filter((file) => {
      const workspace = context.workspaces.find(({ directory }) => file.startsWith(`${directory}/`))
      if (workspace !== undefined) names.add(workspace.name)
      return workspace !== undefined
    })
    if (inputs.length === 0) return undefined
    const sorted = [...names].toSorted(byCodeUnit)
    return {
      inputs,
      args: sorted.map((workspaceName) => `--filter=...${workspaceName}`),
      reason: sorted.join(", ")
    }
  }
})

const pathStep = (name, lane, patterns, command = ["bun", "run", name]) => ({
  name,
  lane,
  command: () => command,
  select: ({ files, context }) => {
    const inputs = files.filter((file) =>
      matchesAny(file, typeof patterns === "function" ? patterns(context) : patterns)
    )
    return inputs.length === 0 ? undefined : { inputs, args: [], reason: inputs[0] }
  }
})

const swiftTestScript = (context) => context.scriptInputs["scripts/test-swift.mjs"] ?? []

const checkSteps = [
  alwaysStep("format:check"),
  alwaysStep("lint"),
  alwaysStep("comments:check"),
  alwaysStep("ratchet:check"),
  alwaysStep("boundaries"),
  alwaysStep("dev:scripts:test"),
  turboStep("typecheck"),
  turboStep("test:coverage"),
  pathStep("typecheck:configs", "javascript", [
    "**/vitest*.config.ts",
    "tsconfig.base.json",
    "tsconfig.configs.json"
  ]),
  pathStep("release:scripts:test", "javascript", (context) => [
    "scripts/release/**",
    "apps/www/public/install.sh",
    "apps/macos/ChromiumHelper/**",
    ...(context.scriptInputs["scripts/release"] ?? [])
  ]),
  pathStep("swift:format:check", "swift-style", [
    "**/*.swift",
    ".swift-format",
    "scripts/swift-format.sh"
  ]),
  pathStep("swift:lint", "swift-style", [
    "**/*.swift",
    ".swiftlint.yml",
    ".swiftlint-baseline.json",
    "scripts/swift-lint.mjs"
  ]),
  pathStep(
    "swift:test",
    "swift",
    (context) => ["packages/swift/**", ...nativeInputs, ...swiftTestScript(context)],
    ["node", "scripts/test-swift.mjs"]
  )
]

export function planChecks({ files: changed, all = false, context }) {
  const files = changed.flatMap((file) => [
    file,
    ...context.swiftLinks
      .filter(({ target }) => file.startsWith(`${target}/`))
      .map(({ link, target }) => `${link}${file.slice(target.length)}`)
  ])
  const tooling = files.find((file) => matchesAny(file, toolingInputs))
  return checkSteps.map((step) => {
    if (step.always) return { step, run: true, args: [], inputs: files, reason: "always" }
    if (all || tooling !== undefined) {
      return { step, run: true, args: [], inputs: files, reason: all ? "--all" : tooling }
    }
    const selection = step.select({ files, context })
    if (selection === undefined) {
      return { step, run: false, args: [], inputs: [], reason: "unchanged" }
    }
    return { step, run: true, ...selection }
  })
}

export const byCodeUnit = (a, b) => {
  if (a < b) return -1
  return a > b ? 1 : 0
}

export function relativeImports(source) {
  return [...source.matchAll(/(?:from|import)\s*\(?\s*["'](\.{1,2}\/[^"']+)["']/g)].map(
    (match) => match[1]
  )
}

function matchesAny(path, patterns) {
  return patterns.some((pattern) => globExpression(pattern).test(path))
}

const globParts = new Map([
  ["**/", "(?:.*/)?"],
  ["**", ".*"],
  ["*", "[^/]*"]
])

const expressions = new Map()
function globExpression(pattern) {
  let expression = expressions.get(pattern)
  if (expression === undefined) {
    const source = pattern
      .split(/(\*\*\/|\*\*|\*)/)
      .map((part) => globParts.get(part) ?? part.replace(/[.+?^${}()|[\]\\]/g, "\\$&"))
      .join("")
    expression = new RegExp(`^${source}$`)
    expressions.set(pattern, expression)
  }
  return expression
}

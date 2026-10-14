// Decides which pre-commit checks a change needs. Pure: scripts/check.mjs
// gathers the changed files and repository facts, this module maps them to
// checks. A check runs when one of its inputs changed; a check missing from
// this table never runs, so every input a check reads must be listed.

// Changing these can change what any check does, so they run everything.
const toolingInputs = [
  "package.json",
  "bun.lock",
  "lefthook.yml",
  "scripts/check.mjs",
  "scripts/check-plan.mjs"
]
// Shared TypeScript and Vitest configuration: every workspace package.
const javascriptInputs = [
  ".node-version",
  "tsconfig.base.json",
  "tsconfig.json",
  "turbo.json",
  "vitest.config.ts"
]
// The tunnel xcframework CodevisorNet links, built from packages/net.
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

/// Turbo tasks run for the changed workspace packages and their dependents.
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
    const sorted = [...names].toSorted()
    return { inputs, args: sorted.map((name) => `--filter=...${name}`), reason: sorted.join(", ") }
  }
})

/// A check whose inputs are fixed path patterns.
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

/// A Swift build that links some packages/swift products. A packages/swift
/// change affects it only when the changed file belongs to a module those
/// products depend on.
const swiftStep = (name, command, { lane = "swift", products, patterns }) => ({
  name,
  lane,
  command: () => command,
  select: ({ files, context }) => {
    const extra = patterns(context)
    const roots = products(context)
    const modules =
      context.swiftPackage === undefined || roots === undefined
        ? undefined
        : swiftModules(context.swiftPackage, roots)
    const inputs = files.filter(
      (file) =>
        matchesAny(file, extra) ||
        (file.startsWith("packages/swift/") &&
          swiftFileAffects(file.slice("packages/swift/".length), context.swiftPackage, modules))
    )
    return inputs.length === 0 ? undefined : { inputs, args: [], reason: inputs[0] }
  }
})

const swiftTestScript = (context) => context.scriptInputs["scripts/test-swift.mjs"] ?? []

const checkSteps = [
  // Fast whole-repository checks run every time. The script tests also read
  // files from across the repository.
  alwaysStep("format:check"),
  alwaysStep("lint"),
  alwaysStep("ratchet:check"),
  alwaysStep("boundaries"),
  alwaysStep("dev:scripts:test"),
  turboStep("typecheck"),
  turboStep("test:coverage"),
  pathStep("release:scripts:test", "javascript", (context) => [
    "scripts/release/**",
    "apps/www/public/install.sh",
    "apps/macos/ChromiumHelper/**",
    ...(context.scriptInputs["scripts/release"] ?? [])
  ]),
  // Quick, so their own lane keeps them off the builds' critical path.
  pathStep("swift:format:check", "swift-style", [
    "**/*.swift",
    ".swift-format",
    "scripts/swift-format.sh"
  ]),
  pathStep("swift:lint", "swift-style", ["**/*.swift", ".swiftlint.yml", "scripts/swift-lint.sh"]),
  pathStep(
    "swift:test",
    "swift",
    (context) => ["packages/swift/**", ...nativeInputs, ...swiftTestScript(context)],
    ["node", "scripts/test-swift.mjs", "--only=packages/swift"]
  ),
  swiftStep(
    "swift:test (screen-sharing-rig)",
    ["node", "scripts/test-swift.mjs", "--only=apps/screen-sharing-rig"],
    {
      products: (context) => context.rigProducts,
      patterns: (context) => [
        "apps/screen-sharing-rig/Package.*",
        "apps/screen-sharing-rig/Sources/**",
        "apps/screen-sharing-rig/Tests/**",
        ...nativeInputs,
        ...swiftTestScript(context)
      ]
    }
  ),
  // A separate build in its own directory: its own lane overlaps it with the
  // packages/swift tests.
  swiftStep("swift:build:ios", ["bun", "run", "swift:build:ios"], {
    lane: "swift-ios",
    products: (context) => context.iosProducts,
    patterns: (context) => [
      "apps/ios/**",
      "apps/shared/**",
      "packages/ghostty-terminal/**",
      "apps/macos/scripts/build-ghostty.sh",
      ...nativeInputs,
      ...(context.scriptInputs["scripts/build-native.mjs"] ?? [])
    ]
  })
]

/// Every check, with whether this change needs it and why.
export function planChecks({ files: changed, all = false, context }) {
  // packages/swift builds and tests some app folders through symlinks; an edit
  // there is also an edit to the package.
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

/// The packages/swift modules (non-test targets) the given products link.
function swiftModules(manifest, products) {
  const targets = new Map(manifest.targets.map((target) => [target.name, target]))
  const modules = new Set()
  const visit = (name) => {
    const target = targets.get(name)
    if (target === undefined || modules.has(name)) return
    modules.add(name)
    for (const dependency of target.dependencies) {
      const dependencyName = dependency.byName?.[0] ?? dependency.target?.[0]
      if (dependencyName !== undefined) visit(dependencyName)
    }
  }
  for (const product of manifest.products.filter(({ name }) => products.includes(name))) {
    product.targets.forEach(visit)
  }
  return modules
}

/// Whether a file inside packages/swift can change a build of `modules`.
/// Without the manifest, every file counts.
function swiftFileAffects(path, manifest, modules) {
  if (manifest === undefined || modules === undefined) return true
  if (path === "Package.swift" || path === "Package.resolved") return true
  const owner = manifest.targets
    .map((target) => ({ target, directory: targetDirectory(target) }))
    .filter(({ directory }) => directory !== undefined && path.startsWith(`${directory}/`))
    .toSorted((left, right) => right.directory.length - left.directory.length)[0]
  // Files outside every module (docs, test configuration) count unless they
  // are documentation.
  if (owner === undefined) return !path.endsWith(".md")
  return modules.has(owner.target.name)
}

function targetDirectory(target) {
  if (target.path !== undefined && target.path !== null) return target.path
  if (target.type === "binary") return undefined
  return `${target.type === "test" ? "Tests" : "Sources"}/${target.name}`
}

/// The packages/swift products an Xcode project links, from its
/// XCSwiftPackageProductDependency entries for that package.
export function xcodeSwiftProducts(projectFile) {
  const section = projectFile.match(
    /\/\* Begin XCSwiftPackageProductDependency section \*\/([\s\S]*?)\/\* End XCSwiftPackageProductDependency section \*\//
  )?.[1]
  if (section === undefined) return undefined
  const products = [
    ...section.matchAll(
      /package = [^;]*"\.\.\/\.\.\/packages\/swift"[^;]*;\s*productName = (\w+);/g
    )
  ].map((match) => match[1])
  return products.length === 0 ? undefined : products
}

/// The relative module paths a script imports, followed transitively by the
/// caller. Only literal relative specifiers count.
export function relativeImports(source) {
  return [...source.matchAll(/(?:from|import)\s*\(?\s*["'](\.{1,2}\/[^"']+)["']/g)].map(
    (match) => match[1]
  )
}

function matchesAny(path, patterns) {
  return patterns.some((pattern) => globExpression(pattern).test(path))
}

const expressions = new Map()
function globExpression(pattern) {
  let expression = expressions.get(pattern)
  if (expression === undefined) {
    const source = pattern
      .split(/(\*\*\/|\*\*|\*)/)
      .map((part) =>
        part === "**/"
          ? "(?:.*/)?"
          : part === "**"
            ? ".*"
            : part === "*"
              ? "[^/]*"
              : part.replace(/[.+?^${}()|[\]\\]/g, "\\$&")
      )
      .join("")
    expression = new RegExp(`^${source}$`)
    expressions.set(pattern, expression)
  }
  return expression
}

import { basename } from "node:path"

const hookNames = new Set(["beforeEach", "afterEach", "beforeAll", "afterAll"])
const runsPerTestFile = (filename) =>
  filename.endsWith(".test.ts") || basename(filename) === "test-setup.ts"

const topLevelHook = (statement) => {
  if (statement.type !== "ExpressionStatement") return undefined
  const { expression } = statement
  if (expression.type !== "CallExpression" || expression.callee.type !== "Identifier") {
    return undefined
  }
  return hookNames.has(expression.callee.name) ? expression : undefined
}

export const noImportTimeTestHooks = {
  create(context) {
    if (runsPerTestFile(context.filename)) return {}
    return {
      Program(program) {
        for (const hook of program.body.map(topLevelHook).filter(Boolean)) {
          context.report({
            node: hook,
            message: `${hook.callee.name}() at the top of a support module runs only for the first test file that imports it. Register cleanup with onTestFinished, or move the hook to the package's src/test-setup.ts.`
          })
        }
      }
    }
  }
}

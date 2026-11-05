const moduleMockMethods = new Set(["mock", "doMock", "unmock", "doUnmock", "resetModules"])

const mockedModuleCall = (node) => {
  const { callee } = node
  if (callee.type !== "MemberExpression" || callee.computed) return undefined
  if (callee.object.type !== "Identifier" || callee.object.name !== "vi") return undefined
  return moduleMockMethods.has(callee.property.name) ? callee.property.name : undefined
}

export const isolatedModuleMocks = {
  create(context) {
    if (context.filename.endsWith(".isolated.test.ts")) return {}
    return {
      CallExpression(node) {
        const method = mockedModuleCall(node)
        if (method === undefined) return
        context.report({
          node,
          message: `vi.${method}() only affects modules loaded after it, and this file shares loaded modules with other test files. Rename it to *.isolated.test.ts.`
        })
      }
    }
  }
}

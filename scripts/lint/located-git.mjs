const launchers = /^(?:spawn|exec|fork)/

const calledName = (node) => {
  const { callee } = node
  if (callee.type === "Identifier") return callee.name
  if (callee.type === "MemberExpression" && !callee.computed) return callee.property.name
  return undefined
}

const launchesCommand = (name) =>
  name !== undefined && (launchers.test(name) || name === "withPriority")

const isBareGit = (node) => node?.type === "Literal" && node.value === "git"

export const locatedGit = {
  create(context) {
    return {
      CallExpression(node) {
        if (!launchesCommand(calledName(node))) return
        const [command] = node.arguments
        if (!isBareGit(command)) return
        context.report({
          node: command,
          message:
            'Run Git through gitExecutable() from @codevisor/worktrees. A bare "git" can be Apple\'s placeholder, which opens the developer tools installer.'
        })
      }
    }
  }
}

const toolDirectives = [
  /^\s*((?:oxlint|eslint)-(?:disable|enable)(?:-next-line|-line)?(?:\s+[\w@][\w@/-]*(?:\s*,\s*[\w@][\w@/-]*)*)?)/,
  /^\s*(@ts-expect-error)/,
  /^\s*(v8 ignore (?:next(?: \d+)?|start|stop|if|else|file))/,
  /^\s*([@#]__PURE__)\s*$/,
  /^\s*(@vite-ignore)\s*$/,
  /^(\/\s*<reference\s+(?:types|path|lib)="[^"]+"\s*\/>)\s*$/
]

function directive(comment) {
  for (const pattern of toolDirectives) {
    const match = pattern.exec(comment.value)
    if (match === null) continue
    const core = match[1]
    const text =
      comment.type === "Block" ? `/* ${core} */` : core.startsWith("/") ? `//${core}` : `// ${core}`
    return { text, bare: comment.value.slice(match[0].length).trim() === "" }
  }
  return undefined
}

const jsdocTypeTag =
  /^@(?:type|param|returns|typedef|template|satisfies|import|callback|property|overload|this|enum)\b/

const isJavaScript = (filename) => /\.[cm]?jsx?$/.test(filename)

function isJSDocTypeAnnotation(comment) {
  if (comment.type !== "Block" || !comment.value.startsWith("*")) return false
  const lines = comment.value
    .slice(1)
    .split("\n")
    .map((line) => line.replace(/^\s*\*?\s?/, "").trim())
    .filter(Boolean)
  return lines.length > 0 && lines.every((line) => jsdocTypeTag.test(line))
}

function isAllowedComment(comment, filename) {
  return comment.type === "Shebang" || (isJavaScript(filename) && isJSDocTypeAnnotation(comment))
}

function removalRange(text, [start, end]) {
  const lineStart = text.lastIndexOf("\n", start - 1) + 1
  const newline = text.indexOf("\n", end)
  const lineEnd = newline === -1 ? text.length : newline
  const before = text.slice(lineStart, start)
  const after = text.slice(end, lineEnd)
  if (before.trim() === "" && after.trim() === "") {
    return [lineStart, newline === -1 ? text.length : newline + 1]
  }
  if (after.trim() === "") return [lineStart + before.trimEnd().length, end]
  return [start, end + (after.length - after.trimStart().length)]
}

export default {
  meta: { name: "codevisor" },
  rules: {
    "no-comments": {
      meta: { fixable: "code" },
      create(context) {
        const { sourceCode } = context
        const emptyContainers = new Map()
        const location = (range) => ({
          start: sourceCode.getLocFromIndex(range[0]),
          end: sourceCode.getLocFromIndex(range[1])
        })
        const report = (range) =>
          context.report({
            loc: location(range),
            message: "Comments are not allowed. Say it in the code, or delete it.",
            fix: (fixer) => fixer.removeRange(removalRange(sourceCode.text, range))
          })
        return {
          JSXExpressionContainer(node) {
            if (node.expression.type === "JSXEmptyExpression") {
              emptyContainers.set(node.range[0], node.range)
            }
          },
          "Program:exit"() {
            const covered = [...emptyContainers.values()]
            for (const comment of sourceCode.getAllComments()) {
              if (isAllowedComment(comment, context.filename)) continue
              const tool = directive(comment)
              if (tool?.bare) continue
              if (tool !== undefined) {
                context.report({
                  loc: location(comment.range),
                  message: "Tool directives cannot carry a reason. Keep only the directive.",
                  fix: (fixer) => fixer.replaceTextRange(comment.range, tool.text)
                })
                continue
              }
              const container = covered.find(
                ([start, end]) => start <= comment.range[0] && comment.range[1] <= end
              )
              if (container === undefined) report(comment.range)
              else if (emptyContainers.delete(container[0])) report(container)
            }
          }
        }
      }
    }
  }
}

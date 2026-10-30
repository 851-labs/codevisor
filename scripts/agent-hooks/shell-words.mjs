const blank = new Set([" ", "\t"])
const wordEnd = new Set([" ", "\t", "\n", "|", "&", ";", "(", ")", "<", ">"])
const redirectOperator = new Set(["<", ">", "&", "|"])
const doubleQuoteEscapes = new Set(["$", "`", '"', "\\", "\n"])

export function parseShell(source) {
  const state = { source, index: 0, heredocs: [] }
  const pipelines = []
  let pipeline = []
  let command = emptyCommand()

  const endCommand = () => {
    if (command.words.length > 0) pipeline.push(command)
    command = emptyCommand()
  }
  const endPipeline = () => {
    endCommand()
    if (pipeline.length > 0) pipelines.push(pipeline)
    pipeline = []
  }

  while (state.index < source.length) {
    const c = source[state.index]
    if (blank.has(c)) state.index++
    else if (c === "\n") {
      endPipeline()
      state.index++
      skipHeredocBodies(state)
    } else if (c === "#") state.index = lineEnd(source, state.index)
    else if (c === "|" && source[state.index + 1] !== "|") {
      endCommand()
      state.index += source[state.index + 1] === "&" ? 2 : 1
    } else if (c === "|" || c === "&" || c === ";" || c === "(" || c === ")") {
      endPipeline()
      state.index++
    } else if (startsRedirect(source, state.index)) readRedirect(state, command)
    else addWord(command, readWord(state))
  }
  endPipeline()
  return pipelines
}

function emptyCommand() {
  return { words: [], skipNextWord: false }
}

function addWord(command, word) {
  if (word === undefined) return
  if (command.skipNextWord) command.skipNextWord = false
  else command.words.push(word)
}

const startsRedirect = (source, index) =>
  (source[index] === "<" || source[index] === ">") && source[index + 1] !== "("

function readRedirect(state, command) {
  const start = state.index
  while (redirectOperator.has(state.source[state.index])) state.index++
  const operator = state.source.slice(start, state.index)
  if (operator.startsWith("<<") && !operator.startsWith("<<<")) readHeredocStart(state)
  else command.skipNextWord = true
}

function readHeredocStart(state) {
  const stripsTabs = state.source[state.index] === "-"
  if (stripsTabs) state.index++
  while (blank.has(state.source[state.index])) state.index++
  const delimiter = readWord(state)
  if (delimiter !== undefined) state.heredocs.push({ delimiter: delimiter.text, stripsTabs })
}

function skipHeredocBodies(state) {
  for (const heredoc of state.heredocs.splice(0)) {
    while (state.index < state.source.length) {
      const end = lineEnd(state.source, state.index)
      const line = state.source.slice(state.index, end)
      state.index = end + 1
      if ((heredoc.stripsTabs ? line.replace(/^\t+/, "") : line) === heredoc.delimiter) break
    }
  }
}

function readWord(state) {
  const word = { text: "", scripts: [] }
  const { source } = state
  if (source[state.index] === "<" || source[state.index] === ">") {
    readSubstitution(state, word, state.index + 2)
    return word
  }
  while (state.index < source.length && !wordEnd.has(source[state.index])) {
    readWordPart(state, word)
  }
  if (isFileDescriptor(word, source[state.index])) return undefined
  return word
}

const isFileDescriptor = (word, next) => /^\d+$/.test(word.text) && (next === "<" || next === ">")

function readWordPart(state, word) {
  const { source } = state
  const c = source[state.index]
  if (c === "\\") readEscape(state, word)
  else if (c === "'") readSingleQuoted(state, word)
  else if (c === '"') readDoubleQuoted(state, word)
  else if (source.startsWith("$'", state.index)) readAnsiQuoted(state, word)
  else if (source.startsWith("$(", state.index)) readSubstitution(state, word, state.index + 2)
  else if (c === "`") readBackticks(state, word)
  else {
    word.text += c
    state.index++
  }
}

function readEscape(state, word) {
  const next = state.source[state.index + 1]
  if (next !== "\n" && next !== undefined) word.text += next
  state.index += 2
}

function readSingleQuoted(state, word) {
  const close = state.source.indexOf("'", state.index + 1)
  const end = close === -1 ? state.source.length : close
  word.text += state.source.slice(state.index + 1, end)
  state.index = end + 1
}

function readAnsiQuoted(state, word) {
  let index = state.index + 2
  while (index < state.source.length && state.source[index] !== "'") {
    if (state.source[index] === "\\") index++
    word.text += state.source[index] ?? ""
    index++
  }
  state.index = index + 1
}

function readDoubleQuoted(state, word) {
  const { source } = state
  state.index++
  while (state.index < source.length && source[state.index] !== '"') {
    const c = source[state.index]
    if (c === "\\" && doubleQuoteEscapes.has(source[state.index + 1])) readEscape(state, word)
    else if (source.startsWith("$(", state.index)) readSubstitution(state, word, state.index + 2)
    else if (c === "`") readBackticks(state, word)
    else {
      word.text += c
      state.index++
    }
  }
  state.index++
}

function readSubstitution(state, word, bodyStart) {
  const end = substitutionEnd(state.source, bodyStart)
  word.scripts.push(state.source.slice(bodyStart, end))
  word.text += state.source.slice(state.index, end + 1)
  state.index = end + 1
}

function readBackticks(state, word) {
  let index = state.index + 1
  let body = ""
  while (index < state.source.length && state.source[index] !== "`") {
    if (state.source[index] === "\\") index++
    body += state.source[index] ?? ""
    index++
  }
  word.scripts.push(body)
  word.text += state.source.slice(state.index, index + 1)
  state.index = index + 1
}

function substitutionEnd(source, start) {
  let depth = 1
  for (let index = start; index < source.length; index++) {
    const c = source[index]
    if (c === "\\") index++
    else if (c === "'" || c === '"' || c === "`") index = quoteEnd(source, index)
    else if (c === "(") depth++
    else if (c === ")" && --depth === 0) return index
  }
  return source.length
}

function quoteEnd(source, start) {
  const quote = source[start]
  for (let index = start + 1; index < source.length; index++) {
    if (source[index] === "\\" && quote !== "'") index++
    else if (source[index] === quote) return index
  }
  return source.length
}

function lineEnd(source, index) {
  const newline = source.indexOf("\n", index)
  return newline === -1 ? source.length : newline
}

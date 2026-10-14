#!/usr/bin/env node
import { execFileSync } from "node:child_process"
import { readFileSync, writeFileSync } from "node:fs"
import { basename, extname } from "node:path"
import { fileURLToPath } from "node:url"

const thirdParty = [
  /^\.repos\//,
  /(^|\/)node_modules\//,
  /(^|\/)Vendor\//,
  /(^|\/)Generated\//,
  /^packages\/swift\/CodeHighlighter\/Resources\//,
  /^packages\/terminal\/resources\/shell-integration\//,
  /^packages\/terminal\/resources\/terminfo\//
]

function skipString(text, index, quote, escapes = true) {
  for (let i = index + 1; i < text.length; i++) {
    if (escapes && text[i] === "\\") i++
    else if (text[i] === quote) return i + 1
  }
  return text.length
}

const lineEnd = (text, index) => {
  const newline = text.indexOf("\n", index)
  return newline === -1 ? text.length : newline
}

function blockEnd(text, index, nested) {
  let depth = 1
  for (let i = index + 2; i < text.length; i++) {
    if (nested && text.startsWith("/*", i)) {
      depth++
      i++
    } else if (text.startsWith("*/", i) && --depth === 0) return i + 2
  }
  return text.length
}

function slashComments(text, { lineComments = true, nested = false, quotes = `"'`, rust = false }) {
  const ranges = []
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (lineComments && text.startsWith("//", i)) {
      ranges.push([i, lineEnd(text, i)])
      i = lineEnd(text, i) - 1
    } else if (text.startsWith("/*", i)) {
      const end = blockEnd(text, i, nested)
      ranges.push([i, end])
      i = end - 1
    } else if (rust && /r#*"/y.test(text.slice(i, i + 64)) && !/\w/.test(text[i - 1] ?? "")) {
      const hashes = /^r(#*)"/.exec(text.slice(i))[1]
      const close = text.indexOf(`"${hashes}`, i + hashes.length + 2)
      i = (close === -1 ? text.length : close + hashes.length + 1) - 1
    } else if (rust && c === "'") {
      const char = /^'(?:\\(?:u\{[0-9a-fA-F]+\}|x[0-9a-fA-F]{2}|.)|[^\\'\n])'/u.exec(text.slice(i))
      if (char !== null) i += char[0].length - 1
    } else if (quotes.includes(c)) {
      i = skipString(text, i, c) - 1
    }
  }
  return ranges
}

const wordBoundary = (character) => character === undefined || /[\s;&|()]/.test(character)

function shellComments(text, offset = 0) {
  const ranges = []
  const heredocs = []
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === "\\") i++
    else if (c === "'") i = skipString(text, i, "'", text[i - 1] === "$") - 1
    else if (c === '"' || c === "`") i = skipString(text, i, c) - 1
    else if (c === "#" && wordBoundary(text[i - 1])) {
      if (!(i === 0 && text.startsWith("#!"))) ranges.push([offset + i, offset + lineEnd(text, i)])
      i = lineEnd(text, i) - 1
    } else if (text.startsWith("<<", i) && text[i + 2] !== "<") {
      const heredoc = /^<<-?\s*(['"]?)([A-Za-z_][\w-]*)\1/.exec(text.slice(i))
      if (heredoc !== null) {
        heredocs.push(heredoc[2])
        i += heredoc[0].length - 1
      }
    } else if (c === "\n" && heredocs.length > 0) {
      for (const delimiter of heredocs.splice(0)) {
        let next = i + 1
        while (next < text.length && text.slice(next, lineEnd(text, next)).trim() !== delimiter) {
          next = lineEnd(text, next) + 1
        }
        i = lineEnd(text, next) - 1
      }
    }
  }
  return ranges
}

function pythonComments(text) {
  const ranges = []
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === "#") {
      if (!(i === 0 && text.startsWith("#!"))) ranges.push([i, lineEnd(text, i)])
      i = lineEnd(text, i) - 1
    } else if (c === '"' || c === "'") {
      const triple = c.repeat(3)
      if (text.startsWith(triple, i)) {
        const close = text.indexOf(triple, i + 3)
        i = (close === -1 ? text.length : close + 3) - 1
      } else i = skipString(text, i, c) - 1
    }
  }
  return ranges
}

function tomlComments(text) {
  const ranges = []
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === "#") {
      ranges.push([i, lineEnd(text, i)])
      i = lineEnd(text, i) - 1
    } else if (c === '"' || c === "'") {
      const triple = c.repeat(3)
      if (text.startsWith(triple, i)) {
        const close = text.indexOf(triple, i + 3)
        i = (close === -1 ? text.length : close + 3) - 1
      } else i = skipString(text, i, c, c === '"') - 1
    }
  }
  return ranges
}

function yamlComments(text) {
  const ranges = []
  const lines = text.split("\n")
  let offset = 0
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    const start = offset
    offset += line.length + 1
    let quote
    let blockScalar = false
    for (let i = 0; i < line.length; i++) {
      const c = line[i]
      if (quote !== undefined) {
        if (quote === '"' && c === "\\") i++
        else if (c === quote) quote = undefined
      } else if ((c === '"' || c === "'") && /^$|[\s:[{,-]$/.test(line.slice(0, i))) quote = c
      else if (c === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
        ranges.push([start + i, start + line.length])
        break
      } else if (/[|>]/.test(c) && /(?:^|[:\s-])$/.test(line.slice(0, i))) {
        blockScalar = /^[|>][+-]?\d*\s*(?:#.*)?$/.test(line.slice(i))
      }
    }
    if (!blockScalar) continue
    const indent = line.length - line.replace(/^\s*(?:-\s+)*/, "").length
    const bodyStart = offset
    let bodyEnd = offset
    while (index + 1 < lines.length) {
      const next = lines[index + 1]
      if (next.trim() !== "" && next.length - next.trimStart().length <= indent) break
      index++
      offset += next.length + 1
      bodyEnd = offset
    }
    if (/^\s*(?:-\s+)?run:/.test(line)) {
      ranges.push(...shellComments(text.slice(bodyStart, bodyEnd), bodyStart))
    }
  }
  return ranges
}

function lineStartComments(text, markers) {
  const ranges = []
  let offset = 0
  for (const line of text.split("\n")) {
    const indent = line.length - line.trimStart().length
    if (markers.some((marker) => line.startsWith(marker, indent))) {
      ranges.push([offset + indent, offset + line.length])
    }
    offset += line.length + 1
  }
  return ranges
}

function sqlComments(text) {
  const ranges = []
  for (let i = 0; i < text.length; i++) {
    if (text.startsWith("--", i)) {
      ranges.push([i, lineEnd(text, i)])
      i = lineEnd(text, i) - 1
    } else if (text.startsWith("/*", i)) {
      const end = blockEnd(text, i, false)
      ranges.push([i, end])
      i = end - 1
    } else if (text[i] === "'") i = skipString(text, i, "'", false) - 1
  }
  return ranges
}

function markupComments(text) {
  const ranges = []
  const pattern = /<!--[\s\S]*?-->|<(script|style)\b[^>]*>([\s\S]*?)<\/\1>/g
  for (const match of text.matchAll(pattern)) {
    if (match[1] === undefined) {
      ranges.push([match.index, match.index + match[0].length])
      continue
    }
    const bodyStart = match.index + match[0].indexOf(">") + 1
    const body = match[2]
    const inner = slashComments(body, { lineComments: match[1] === "script", quotes: "\"'`" })
    ranges.push(...inner.map(([a, b]) => [bodyStart + a, bodyStart + b]))
  }
  return ranges
}

const cFamily = (text) => slashComments(text, {})
const javaScriptComments = (text) => slashComments(text, { quotes: "\"'`" })
const outsideOxlint = /^(?:apps\/macos|packages\/swift)\/.*\.[cm]?[jt]s$/
const byExtension = {
  ".c": cFamily,
  ".cc": cFamily,
  ".cpp": cFamily,
  ".h": cFamily,
  ".m": cFamily,
  ".mm": cFamily,
  ".modulemap": cFamily,
  ".strings": cFamily,
  ".jxa": javaScriptComments,
  ".rs": (text) => slashComments(text, { nested: true, quotes: '"', rust: true }),
  ".css": (text) => slashComments(text, { lineComments: false }),
  ".json": (text) => slashComments(text, { quotes: '"' }),
  ".jsonc": (text) => slashComments(text, { quotes: '"' }),
  ".sh": shellComments,
  ".bash": shellComments,
  ".zsh": shellComments,
  ".py": pythonComments,
  ".toml": tomlComments,
  ".yml": yamlComments,
  ".yaml": yamlComments,
  ".sql": sqlComments,
  ".html": markupComments,
  ".svg": markupComments,
  ".xml": markupComments,
  ".plist": markupComments,
  ".entitlements": markupComments,
  ".xcprivacy": markupComments,
  ".stringsdict": markupComments,
  ".gitignore": (text) => lineStartComments(text, ["#"]),
  ".gitmodules": (text) => lineStartComments(text, ["#", ";"]),
  ".example": (text) => lineStartComments(text, ["#"])
}
const byName = {
  Dockerfile: (text) => lineStartComments(text, ["#"]),
  ".gitignore": byExtension[".gitignore"],
  ".gitmodules": byExtension[".gitmodules"],
  ".zshenv": shellComments
}

const directives = [
  /^# shellcheck (?:disable|enable|source|shell)=[\w,./-]+/,
  /^# syntax=\S+/,
  /^--> statement-breakpoint/
]

export function commentLexer(path, text) {
  const name = basename(path)
  const lexer = byName[name] ?? byExtension[extname(name)]
  if (lexer !== undefined) return lexer
  if (outsideOxlint.test(path)) return javaScriptComments
  if (/^#!\/(?:usr\/)?bin\/(?:env (?:ba|z)?sh|(?:ba|z)?sh)\b/.test(text)) return shellComments
  return undefined
}

export function findComments(path, text) {
  const lexer = commentLexer(path, text)
  if (lexer === undefined) return []
  return lexer(text).flatMap(([start, end]) => {
    const comment = text.slice(start, end)
    const directive = directives.map((pattern) => pattern.exec(comment)).find(Boolean)?.[0]
    if (directive === undefined) return [[start, end]]
    return comment.trimEnd() === directive ? [] : [[start, end, directive]]
  })
}

export function removeComments(text, ranges) {
  if (ranges.length === 0) return text
  const sorted = ranges.toSorted((a, b) => a[0] - b[0])
  const hadTrailingNewline = text.endsWith("\n")
  const source = text.split("\n")
  if (hadTrailingNewline) source.pop()
  const edited = []
  let offset = 0
  for (const line of source) {
    const start = offset
    const end = offset + line.length
    offset = end + 1
    const hits = sorted.filter(([a, b]) => a <= end && b > start)
    if (hits.length === 0) {
      edited.push({ text: line, dropped: false })
      continue
    }
    let kept = ""
    let cursor = start
    for (const [a, b, replacement] of hits) {
      if (a > cursor) kept += text.slice(cursor, a)
      if (replacement !== undefined && a >= start) kept += replacement
      cursor = Math.max(cursor, Math.min(b, end))
    }
    kept += text.slice(cursor, end)
    edited.push(kept.trim() === "" ? { dropped: true } : { text: kept.trimEnd(), dropped: false })
  }
  const lines = []
  const blank = (index) =>
    index < edited.length && !edited[index].dropped && edited[index].text.trim() === ""
  for (let i = 0; i < edited.length; i++) {
    if (!edited[i].dropped) {
      lines.push(edited[i].text)
      continue
    }
    while (i + 1 < edited.length && edited[i + 1].dropped) i++
    const previous = lines.at(-1)
    if (previous === undefined || previous.trim() === "" || /[{([]$/.test(previous)) {
      while (blank(i + 1)) i++
    }
    const following = edited
      .slice(i + 1)
      .find((line) => !line.dropped)
      ?.text.trim()
    if (lines.at(-1)?.trim() === "" && (following === undefined || /^[})\]]/.test(following))) {
      lines.pop()
    }
  }
  while (lines.length > 0 && lines.at(-1).trim() === "") lines.pop()
  return lines.length === 0 ? "" : `${lines.join("\n")}\n`
}

function repositoryFiles(root) {
  return execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  })
    .split("\0")
    .filter((path) => path !== "" && !thirdParty.some((pattern) => pattern.test(path)))
}

function main() {
  const root = fileURLToPath(new URL("..", import.meta.url))
  const fix = process.argv.includes("--fix")
  const violations = []
  for (const path of repositoryFiles(root)) {
    let text
    try {
      text = readFileSync(`${root}/${path}`, "utf8")
    } catch {
      continue
    }
    const comments = findComments(path, text)
    if (comments.length === 0) continue
    if (fix) {
      writeFileSync(`${root}/${path}`, removeComments(text, comments))
      continue
    }
    for (const [start] of comments) {
      const line = text.slice(0, start).split("\n").length
      violations.push(`${path}:${line}: ${text.slice(start, lineEnd(text, start)).trim()}`)
    }
  }
  if (violations.length > 0) {
    console.error(violations.join("\n"))
    console.error(
      `\n${violations.length} comments. Comments are not allowed: say it in the code, or delete it.`
    )
    process.exitCode = 1
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main()

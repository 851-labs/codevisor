// Entry point for the Shiki highlighter bundle that runs inside
// JavaScriptCore in the macOS app. Bundled by build-highlighter.mjs into a
// self-contained IIFE exposing `herdmanHighlight` on the global object.
//
// Uses Shiki's pure-JavaScript regex engine (no WASM — JSC-friendly) with a
// curated grammar set matching the languages that show up in agent chats.
import { createHighlighterCoreSync } from "@shikijs/core"
import { createJavaScriptRegexEngine } from "@shikijs/engine-javascript"

import bash from "@shikijs/langs/bash"
import c from "@shikijs/langs/c"
import cpp from "@shikijs/langs/cpp"
import css from "@shikijs/langs/css"
import diff from "@shikijs/langs/diff"
import go from "@shikijs/langs/go"
import html from "@shikijs/langs/html"
import java from "@shikijs/langs/java"
import javascript from "@shikijs/langs/javascript"
import json from "@shikijs/langs/json"
import jsx from "@shikijs/langs/jsx"
import kotlin from "@shikijs/langs/kotlin"
import markdown from "@shikijs/langs/markdown"
import python from "@shikijs/langs/python"
import ruby from "@shikijs/langs/ruby"
import rust from "@shikijs/langs/rust"
import sql from "@shikijs/langs/sql"
import swift from "@shikijs/langs/swift"
import toml from "@shikijs/langs/toml"
import tsx from "@shikijs/langs/tsx"
import typescript from "@shikijs/langs/typescript"
import yaml from "@shikijs/langs/yaml"

const highlighter = createHighlighterCoreSync({
  themes: [],
  langs: [
    bash, c, cpp, css, diff, go, html, java, javascript, json, jsx, kotlin,
    markdown, python, ruby, rust, sql, swift, toml, tsx, typescript, yaml,
  ],
  // target ES2018: "auto" emits `v`-flag regexes on engines that claim
  // support, but JavaScriptCore builds differ in `v`-flag behavior (the CI
  // runner's JSC silently dropped the Swift comment rule via `forgiving`).
  // Conservative syntax compiles identically on every JSC we run on.
  engine: createJavaScriptRegexEngine({ forgiving: true, target: "ES2018" }),
})

const loadedLanguages = new Set(highlighter.getLoadedLanguages())

// Themes are parsed and normalized once per distinct key (the Swift side
// passes a stable key: the theme id).
const themeCache = new Map()

/**
 * Tokenizes `code` with the grammar for `lang` under the given theme.
 * Returns a JSON string: an array of lines, each an array of
 * `{ content, color }` tokens — or the literal string "null" when the
 * language is unknown (caller renders plain text).
 */
globalThis.herdmanHighlight = function herdmanHighlight(code, lang, themeKey, themeJSON) {
  const language = resolveLanguage(lang)
  if (language == null) return "null"

  let theme = themeCache.get(themeKey)
  if (theme == null) {
    theme = JSON.parse(themeJSON)
    if (!theme.name) theme.name = themeKey
    themeCache.set(themeKey, theme)
  }

  const lines = highlighter.codeToTokensBase(code, { lang: language, theme })
  return JSON.stringify(
    lines.map((line) => line.map((token) => ({ content: token.content, color: token.color })))
  )
}

// Common aliases the grammar set covers; anything unknown returns null so the
// caller keeps plain text rather than mis-highlighting.
const languageAliases = {
  js: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  ts: "typescript",
  mts: "typescript",
  cts: "typescript",
  py: "python",
  rb: "ruby",
  golang: "go",
  kt: "kotlin",
  md: "markdown",
  sh: "bash",
  shell: "bash",
  zsh: "bash",
  yml: "yaml",
  "c++": "cpp",
  jsonc: "json",
  patch: "diff",
}

function resolveLanguage(lang) {
  if (typeof lang !== "string" || lang.length === 0) return null
  const normalized = lang.toLowerCase()
  if (loadedLanguages.has(normalized)) return normalized
  const alias = languageAliases[normalized]
  if (alias != null && loadedLanguages.has(alias)) return alias
  return null
}

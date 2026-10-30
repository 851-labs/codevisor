#!/usr/bin/env node
import { readFileSync, realpathSync } from "node:fs"
import { basename } from "node:path"
import { fileURLToPath } from "node:url"

import { parseShell } from "./shell-words.mjs"

const blockedExitCode = 2
const maxNesting = 4
const patternKillers = new Set(["pkill", "killall"])
const processLookups = new Set(["pgrep", "pidof", "ps", "lsof"])
const shells = new Set(["sh", "bash", "zsh", "dash", "ksh"])
const leadingKeywords = new Set(["{", "!", "if", "then", "else", "elif", "do", "while", "until"])
const assignment = /^[A-Za-z_][A-Za-z0-9_]*=/

const wrappers = {
  sudo: (args) => afterOptions(args, ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"]),
  doas: (args) => afterOptions(args, ["-u", "-C"]),
  env: (args) => dropAssignments(afterOptions(args, ["-u", "-C", "-P", "-S"])),
  nice: (args) => afterOptions(args, ["-n"]),
  nohup: (args) => args,
  time: (args) => afterOptions(args, []),
  exec: (args) => afterOptions(args, ["-a"]),
  builtin: (args) => args,
  command: (args) => (/^-[vV]/.test(args[0]?.text ?? "") ? [] : afterOptions(args, [])),
  caffeinate: (args) => afterOptions(args, ["-t", "-w"]),
  timeout: (args) => afterOptions(args, ["-s", "-k"]).slice(1),
  xargs: (args) => afterOptions(args, ["-I", "-L", "-n", "-P", "-s", "-E", "-J", "-R", "-S", "-d"])
}

const sshValueOptions = "bcDEeFIiJLlmOopQRSWwBP".split("").map((letter) => `-${letter}`)

export function broadKillReason(command) {
  const offense = broadKillIn(command, 0)
  if (offense === undefined) return undefined
  return `Blocked ${offense}: it kills every matching process on this machine, including other agents, dev runners and apps. Find PIDs with \`pgrep -fl <pattern>\` (options before the pattern), check them, then \`kill <pid>\` only the ones you started, or \`kill -- -<pgid>\` for your own process group. macOS pkill reads flags after the pattern as more patterns: \`pkill -f x -n\` matched --no-chrome in every Claude process. See AGENTS.md`
}

function broadKillIn(source, depth) {
  if (depth > maxNesting) return undefined
  const tainted = new Map()
  for (const pipeline of parseShell(source)) {
    for (const [position, command] of pipeline.entries()) {
      const earlier = pipeline.slice(0, position)
      const offense =
        nestedBroadKill(command.words, depth) ??
        invocationBroadKill(resolve(command.words), earlier, tainted, depth)
      if (offense !== undefined) return offense
      recordTaint(command.words, tainted, depth)
    }
  }
  return undefined
}

function nestedBroadKill(words, depth) {
  for (const script of words.flatMap((word) => word.scripts)) {
    const offense = broadKillIn(script, depth + 1)
    if (offense !== undefined) return offense
  }
  return undefined
}

function invocationBroadKill(invocation, earlier, tainted, depth) {
  const { name, args } = invocation
  if (patternKillers.has(name)) return `\`${name}\``
  if (name === "kill") return killBroadKill(invocation, earlier, tainted, depth)
  const inner = innerScript(name, args)
  if (inner === undefined) return undefined
  return broadKillIn(inner, depth + 1)
}

function killBroadKill({ args, viaXargs }, earlier, tainted, depth) {
  if (killTargets(args).some((target) => target.text === "-1")) return "`kill -1`"
  const lookup =
    args.map((arg) => wordLookup(arg, tainted, depth)).find(Boolean) ??
    (viaXargs ? earlier.map((stage) => commandLookup(stage.words, depth)).find(Boolean) : undefined)
  if (lookup === undefined) return undefined
  return `\`kill\` of PIDs straight from \`${lookup}\``
}

function killTargets(args) {
  const first = args[0]?.text ?? ""
  let index = 0
  if (first === "-s" || first === "-n") index = 2
  else if (/^-[lL]/.test(first)) return []
  else if (first.startsWith("-") && first !== "--") index = 1
  if (args[index]?.text === "--") index++
  return args.slice(index)
}

function wordLookup(word, tainted, depth) {
  const fromScript = word.scripts.map((script) => scriptLookup(script, depth + 1)).find(Boolean)
  if (fromScript !== undefined) return fromScript
  return [...tainted.entries()].find(([variable]) => mentions(word.text, variable))?.[1]
}

const mentions = (text, variable) =>
  text.includes(`$${variable}`) ||
  text.includes(`\${${variable}}`) ||
  text.includes(`\${${variable}[`)

function scriptLookup(source, depth) {
  if (depth > maxNesting) return undefined
  for (const pipeline of parseShell(source)) {
    const lookup = pipeline.map((command) => commandLookup(command.words, depth)).find(Boolean)
    if (lookup !== undefined) return lookup
  }
  return undefined
}

function commandLookup(words, depth) {
  const { name } = resolve(words)
  if (processLookups.has(name)) return name
  return words
    .flatMap((word) => word.scripts)
    .map((script) => scriptLookup(script, depth + 1))
    .find(Boolean)
}

function recordTaint(words, tainted, depth) {
  if (words[0]?.text === "for" && words[2]?.text === "in") {
    const lookup = words
      .slice(3)
      .map((word) => wordLookup(word, tainted, depth))
      .find(Boolean)
    if (lookup !== undefined) tainted.set(words[1].text, lookup)
    return
  }
  for (const word of words) {
    if (!assignment.test(word.text)) break
    const lookup = wordLookup(word, tainted, depth)
    if (lookup !== undefined) tainted.set(word.text.slice(0, word.text.indexOf("=")), lookup)
  }
}

function resolve(words) {
  let rest = dropAssignments(words.filter((word, index) => !isLeadingKeyword(words, index)))
  let viaXargs = false
  while (rest.length > 0 && Object.hasOwn(wrappers, commandName(rest[0]))) {
    const name = commandName(rest[0])
    if (name === "xargs") viaXargs = true
    rest = wrappers[name](rest.slice(1))
  }
  return { name: rest.length > 0 ? commandName(rest[0]) : "", args: rest.slice(1), viaXargs }
}

const isLeadingKeyword = (words, index) =>
  words.slice(0, index + 1).every((word) => leadingKeywords.has(word.text))

const commandName = (word) => basename(word.text)

function innerScript(name, args) {
  if (shells.has(name)) return shellCommandArgument(args)
  if (name === "eval") return args.map((arg) => arg.text).join(" ")
  if (name === "ssh")
    return afterOptions(args, sshValueOptions)
      .slice(1)
      .map((arg) => arg.text)
      .join(" ")
  return undefined
}

function shellCommandArgument(args) {
  for (const [index, arg] of args.entries()) {
    if (!arg.text.startsWith("-")) return undefined
    if (isShortOptionCluster(arg.text) && arg.text.includes("c")) return args[index + 1]?.text
  }
  return undefined
}

const isShortOptionCluster = (text) => /^-[A-Za-z]+$/.test(text)

function afterOptions(args, valueOptions) {
  let index = 0
  while (index < args.length && args[index].text.startsWith("-")) {
    const option = args[index].text
    index++
    if (option === "--") break
    if (valueOptions.includes(option)) index++
  }
  return args.slice(index)
}

function dropAssignments(words) {
  const first = words.findIndex((word) => !assignment.test(word.text))
  return first === -1 ? [] : words.slice(first)
}

function hookCommand(payload) {
  const command =
    payload?.tool_input?.command ??
    payload?.toolInput?.command ??
    payload?.toolCall?.args?.CommandLine ??
    payload?.command
  if (Array.isArray(command)) return command.join(" ")
  return typeof command === "string" ? command : ""
}

function parsePayload(text) {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

function main() {
  const payload = parsePayload(readFileSync(0, "utf8"))
  const reason = broadKillReason(hookCommand(payload))
  if (reason === undefined) return
  if (payload.toolCall !== undefined) {
    process.stdout.write(`${JSON.stringify({ decision: "deny", reason })}\n`)
    return
  }
  process.stderr.write(`${reason}\n`)
  process.exitCode = blockedExitCode
}

const isEntryPoint = (path) =>
  path !== undefined && realpathSync(path) === fileURLToPath(import.meta.url)

if (isEntryPoint(process.argv[1])) main()

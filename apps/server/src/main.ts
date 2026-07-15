#!/usr/bin/env node
import { parseArgs, runServe } from "./serve.js"

const command = process.argv[2] ?? "serve"
if (command !== "serve") {
  console.error(`Unsupported command: ${command}`)
  process.exitCode = 1
} else {
  void runServe(parseArgs(process.argv.slice(3)))
}

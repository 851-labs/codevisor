import { expect, it } from "vitest"

import { terminalTitleStatus } from "./terminal-title-status.js"

it.each([
  ["⠂ Claude Code", "Claude Code", "working"],
  ["⠐ Fix the login bug", "Fix the login bug", "working"],
  ["◐ Claude Code", "Claude Code", "working"],
  ["◒ Claude Code", "Claude Code", "working"],
  ["✳ Claude Code", "Claude Code", "idle"],
  ["✻ Claude Code", "Claude Code", undefined],
  ["· task", "task", undefined],
  ["⠋ Working on X", "Working on X", "working"],
  ["codex ⠙ my-repo", "codex ⠙ my-repo", "working"],
  ["my-repo ⠸", "my-repo ⠸", "working"],
  ["my-repo⠸", "my-repo⠸", undefined],
  ["⠋ ⠙ task", "⠙ task", "working"],
  ["  ⠙   task  ", "task", "working"],
  ["⠋task", "⠋task", undefined],
  ["✳", undefined, undefined],
  ["⠋   ", undefined, "working"],
  ["vim README.md", "vim README.md", undefined],
  ["★task", "★task", undefined],
  ["✨ deploy", "✨ deploy", undefined],
  [" 修复🙂标题 ", "修复🙂标题", undefined],
  ["", undefined, undefined]
] as const)("reads %j as %j, %s", (raw, title, activity) => {
  expect(terminalTitleStatus(raw)).toEqual({ title, activity })
})

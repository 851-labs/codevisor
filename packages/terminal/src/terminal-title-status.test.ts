import { expect, it } from "vitest"

import { terminalTitleStatus } from "./terminal-title-status.js"

it.each([
  // Claude Code: braille (<= 2.1.227) and half-circle (2.1.228+) busy
  // spinners, `✳` at its prompt.
  ["⠂ Claude Code", "Claude Code", "working"],
  ["⠐ Fix the login bug", "Fix the login bug", "working"],
  ["◐ Claude Code", "Claude Code", "working"],
  ["◒ Claude Code", "Claude Code", "working"],
  ["✳ Claude Code", "Claude Code", "idle"],
  // Other Claude glyphs are stripped but announce nothing.
  ["✻ Claude Code", "Claude Code", undefined],
  ["· task", "task", undefined],
  // Codex: a spinner frame as its own word, anywhere.
  ["⠋ Working on X", "Working on X", "working"],
  ["codex ⠙ my-repo", "codex ⠙ my-repo", "working"],
  ["my-repo ⠸", "my-repo ⠸", "working"],
  ["my-repo⠸", "my-repo⠸", undefined],
  // Only one glyph, and only before a word boundary.
  ["⠋ ⠙ task", "⠙ task", "working"],
  ["  ⠙   task  ", "task", "working"],
  ["⠋task", "⠋task", undefined],
  ["✳", undefined, undefined],
  ["⠋   ", undefined, "working"],
  // Plain titles and unrecognized decorations are left alone.
  ["vim README.md", "vim README.md", undefined],
  ["★task", "★task", undefined],
  ["✨ deploy", "✨ deploy", undefined],
  [" 修复🙂标题 ", "修复🙂标题", undefined],
  ["", undefined, undefined]
] as const)("reads %j as %j, %s", (raw, title, activity) => {
  expect(terminalTitleStatus(raw)).toEqual({ title, activity })
})

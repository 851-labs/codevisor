import { expect, it } from "vitest"

import { macEditingCommands } from "./browser-key-commands.js"

const meta = 4
const shift = 8

it.each([
  ["KeyA", meta, ["selectAll"]],
  ["KeyV", meta, ["paste"]],
  ["KeyZ", meta, ["undo"]],
  ["KeyZ", meta | shift, ["redo"]],
  ["ArrowLeft", meta, ["moveToLeftEndOfLine"]],
  ["ArrowLeft", meta | shift, ["moveToLeftEndOfLineAndModifySelection"]],
  ["Backspace", meta, ["deleteToBeginningOfLine"]]
])("maps %s with modifiers %i to %j", (code, modifiers, commands) => {
  expect(macEditingCommands({ code, modifiers })).toEqual(commands)
})

it.each([
  ["KeyA", 0],
  ["KeyA", 2],
  ["KeyA", meta | 1],
  ["KeyQ", meta],
  ["KeyV", meta | shift]
])("sends no editing command for %s with modifiers %i", (code, modifiers) => {
  expect(macEditingCommands({ code, modifiers })).toEqual([])
})

it("sends no editing command for a key without a code", () => {
  expect(macEditingCommands({ modifiers: meta })).toEqual([])
})

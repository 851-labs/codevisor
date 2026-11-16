const meta = 4
const shift = 8

const commandKeys: Readonly<Record<string, string>> = {
  KeyA: "selectAll",
  KeyC: "copy",
  KeyV: "paste",
  KeyX: "cut",
  KeyZ: "undo",
  Backspace: "deleteToBeginningOfLine",
  Delete: "deleteToEndOfLine",
  ArrowLeft: "moveToLeftEndOfLine",
  ArrowRight: "moveToRightEndOfLine",
  ArrowUp: "moveToBeginningOfDocument",
  ArrowDown: "moveToEndOfDocument"
}

const shiftedCommandKeys: Readonly<Record<string, string>> = {
  KeyZ: "redo",
  ArrowLeft: "moveToLeftEndOfLineAndModifySelection",
  ArrowRight: "moveToRightEndOfLineAndModifySelection",
  ArrowUp: "moveToBeginningOfDocumentAndModifySelection",
  ArrowDown: "moveToEndOfDocumentAndModifySelection"
}

export const browserHostIsMac = (native: boolean | undefined): boolean =>
  native === true || process.platform === "darwin"

export const macEditingCommands = (key: {
  readonly code?: string
  readonly modifiers: number
}): string[] => {
  const code = key.code ?? ""
  if (key.modifiers === meta) return commandFor(commandKeys, code)
  if (key.modifiers === (meta | shift)) return commandFor(shiftedCommandKeys, code)
  return []
}

const commandFor = (commands: Readonly<Record<string, string>>, code: string): string[] => {
  const command = commands[code]
  return command === undefined ? [] : [command]
}

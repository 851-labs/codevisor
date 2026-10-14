export interface ShellPrompt {
  readonly observe: (data: string) => void
  readonly running: () => boolean | undefined
}

const MARK = "\u001b]133;"

export const makeShellPrompt = (): ShellPrompt => {
  let running: boolean | undefined
  let carry = ""
  return {
    observe: (data) => {
      const text = carry + data
      let index = text.indexOf(MARK)
      while (index !== -1) {
        const kind = text[index + MARK.length]
        if (kind === "C") running = true
        else if (kind === "A" || kind === "D") running = false
        index = text.indexOf(MARK, index + MARK.length)
      }
      carry = text.slice(-MARK.length)
    },
    running: () => running
  }
}
